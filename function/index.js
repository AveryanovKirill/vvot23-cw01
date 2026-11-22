const { createHash } = require('node:crypto');
const { createWriteStream, openAsBlob } = require('node:fs');
const { mkdtemp, rm } = require('node:fs/promises');
const { tmpdir } = require('node:os');
const { join } = require('node:path');
const { pipeline } = require('node:stream/promises');
const { DynamoDBClient, GetItemCommand, PutItemCommand } = require('@aws-sdk/client-dynamodb');
const { ZipFile } = require('yazl');
const { downloadFile, validateSourceUrl } = require('./download');

const MAX_ARCHIVE_BYTES = 2_000_000;

function archiveKey(message) {
  const timestamp = Number(message.attributes?.SentTimestamp);
  if (!message.message_id || !Number.isSafeInteger(timestamp) || timestamp <= 0 || timestamp >= 2 ** 48) {
    throw new Error('В событии отсутствуют идентификатор или время отправки сообщения');
  }

  // Первые 48 бит — время отправки в мс. Хеш уникального ID очереди
  // заполняет случайные поля UUIDv7 и сохраняет ключ при повторной доставке.
  const bytes = createHash('sha256').update(message.message_id).digest().subarray(0, 16);
  bytes.writeUIntBE(timestamp, 0, 6);
  bytes[6] = (bytes[6] & 0x0f) | 0x70;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}.zip`;
}

function parseTask(body) {
  const task = JSON.parse(body);
  if (typeof task?.name !== 'string' || !task.name || task.name.length > 255 ||
      /[/\\:\x00-\x1f\x7f]/.test(task.name) || ['.', '..'].includes(task.name)) {
    throw new Error('Некорректное имя файла для ZIP');
  }
  if (typeof task.url !== 'string' || task.url.length > 8192) {
    throw new Error('Некорректный URL исходного файла');
  }
  validateSourceUrl(task.url);
  return task;
}

async function zipFile(source, name, destination) {
  const zip = new ZipFile();
  zip.on('error', (error) => zip.outputStream.destroy(error));
  zip.addFile(source, name);
  zip.end();
  await pipeline(zip.outputStream, createWriteStream(destination));
}

async function uploadArchive(bucket, key, path, token) {
  const file = await openAsBlob(path, { type: 'application/zip' });
  if (file.size > MAX_ARCHIVE_BYTES) {
    throw new Error('ZIP превышает 2 МБ и может не пройти через API Gateway');
  }

  const response = await fetch(`https://storage.yandexcloud.net/${bucket}/${key}`, {
    method: 'PUT',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/zip',
      'Content-Disposition': `attachment; filename="${key}"`,
    },
    body: file,
    signal: AbortSignal.timeout(90_000),
    redirect: 'error',
  });
  await response.body?.cancel();
  if (!response.ok) {
    throw new Error(`Object Storage ответил HTTP ${response.status}`);
  }
}

async function handler(event, context) {
  if (event.messages?.length !== 1) {
    throw new Error('Обработчик ожидает одно сообщение Yandex Message Queue');
  }
  const message = event.messages[0].details.message;
  const { name, url } = parseTask(message.body);
  const key = archiveKey(message);
  const token = context.token?.access_token;
  if (!token) {
    throw new Error('У функции отсутствует IAM-токен сервисного аккаунта');
  }

  const table = process.env.ARCHIVE_TABLE;
  const ydb = new DynamoDBClient({
    endpoint: process.env.YDB_ENDPOINT,
    region: 'ru-central1',
    credentials: {
      accessKeyId: process.env.YDB_ACCESS_KEY_ID,
      secretAccessKey: process.env.YDB_SECRET_KEY,
    },
  });

  // Исключения передаются триггеру, чтобы очередь могла переместить задание в DLQ.
  try {
    const existing = await ydb.send(new GetItemCommand({
      TableName: table,
      Key: { key: { S: key } },
      ConsistentRead: true,
    }), { abortSignal: AbortSignal.timeout(30_000) });
    if (existing.Item) {
      return { key };
    }

    const temp = await mkdtemp(join(tmpdir(), 'vvot23-'));
    try {
      const source = join(temp, 'source');
      const archive = join(temp, 'archive.zip');
      await downloadFile(url, source);
      await zipFile(source, name, archive);
      await uploadArchive(process.env.ARCHIVE_BUCKET, key, archive, token);

      // Сначала сохраняем ZIP, затем регистрируем его в YDB.
      await ydb.send(new PutItemCommand({
        TableName: table,
        Item: { key: { S: key }, name: { S: name }, url: { S: url } },
      }), { abortSignal: AbortSignal.timeout(30_000) });
      console.info(`Архив сохранён: ${key}`);
      return { key };
    } finally {
      await rm(temp, { recursive: true, force: true });
    }
  } finally {
    ydb.destroy();
  }
}

module.exports = { handler, archiveKey, parseTask, zipFile };
