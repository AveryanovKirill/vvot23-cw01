const dns = require('node:dns/promises');
const fs = require('node:fs');
const http = require('node:http');
const https = require('node:https');
const { isIP } = require('node:net');
const { Transform } = require('node:stream');
const { pipeline } = require('node:stream/promises');
const ipaddr = require('ipaddr.js');

const MAX_SOURCE_BYTES = 32 * 1024 * 1024;
const MAX_REDIRECTS = 5;

function validateSourceUrl(value) {
  const url = new URL(value);
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) {
    throw new Error('Источник должен быть HTTP(S) URL без учётных данных');
  }
  return url;
}

function publicAddress(address) {
  return ipaddr.process(address).range() === 'unicast';
}

async function openSource(url, signal) {
  const host = url.hostname.replace(/^\[|\]$/g, '');
  const family = isIP(host);
  const addresses = family ? [{ address: host, family }] : await dns.lookup(host, { all: true });
  const target = addresses.find(({ address }) => publicAddress(address));
  if (!target) {
    throw new Error('У источника должен быть публичный IP-адрес');
  }

  // Подключаемся к проверенному IP, сохраняя исходный домен для Host и TLS.
  const transport = url.protocol === 'https:' ? https : http;
  return new Promise((resolve, reject) => {
    const request = transport.get(url, {
      agent: false,
      signal,
      family: target.family,
      lookup(_hostname, _options, callback) {
        callback(null, target.address, target.family);
      },
    }, resolve);
    request.on('error', reject);
  });
}

async function downloadFile(sourceUrl, path) {
  let url = validateSourceUrl(sourceUrl);
  const signal = AbortSignal.timeout(120_000);

  for (let redirects = 0; redirects <= MAX_REDIRECTS; redirects += 1) {
    const response = await openSource(url, signal);
    const status = response.statusCode;
    if ([301, 302, 303, 307, 308].includes(status) && response.headers.location) {
      response.destroy();
      // Адрес назначения проходит ту же проверку после каждого перенаправления.
      url = validateSourceUrl(new URL(response.headers.location, url));
      continue;
    }

    if (status < 200 || status >= 300 || status === 206) {
      response.destroy();
      throw new Error(`Источник ответил HTTP ${status}`);
    }
    if (Number(response.headers['content-length']) > MAX_SOURCE_BYTES) {
      response.destroy();
      throw new Error('Размер исходного файла превышает 32 МиБ');
    }

    let received = 0;
    const limit = new Transform({
      transform(chunk, _encoding, callback) {
        received += chunk.length;
        if (received > MAX_SOURCE_BYTES) {
          callback(new Error('Размер исходного файла превышает 32 МиБ'));
          return;
        }
        callback(null, chunk);
      },
    });

    await pipeline(response, limit, fs.createWriteStream(path), { signal });
    return;
  }
  throw new Error('Слишком много перенаправлений при скачивании');
}

module.exports = { downloadFile, validateSourceUrl };
