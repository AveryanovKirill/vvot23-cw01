resource "yandex_message_queue" "failed" {
  name                      = "${local.prefix}-failed-tasks"
  access_key                = yandex_iam_service_account_static_access_key.queue_admin.access_key
  secret_key                = yandex_iam_service_account_static_access_key.queue_admin.secret_key
  message_retention_seconds = 14 * 24 * 60 * 60
}

resource "yandex_message_queue" "tasks" {
  name                       = "${local.prefix}-tasks"
  access_key                 = yandex_iam_service_account_static_access_key.queue_admin.access_key
  secret_key                 = yandex_iam_service_account_static_access_key.queue_admin.secret_key
  visibility_timeout_seconds = 900
  receive_wait_time_seconds  = 20
  message_retention_seconds  = 24 * 60 * 60
  redrive_policy = jsonencode({
    deadLetterTargetArn = yandex_message_queue.failed.arn
    maxReceiveCount     = 1
  })
}

resource "yandex_ydb_database_serverless" "archives" {
  name                = "${local.prefix}-ydb"
  deletion_protection = false

  serverless_database {
    enable_throttling_rcu_limit = true
    throttling_rcu_limit        = 10
    storage_size_limit          = 1
  }
}

# Таблица называется archives по заданию. key — единственный первичный ключ.
resource "aws_dynamodb_table" "archives" {
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "key"

  attribute {
    name = "key"
    type = "S"
  }

  depends_on = [yandex_ydb_database_serverless.archives, yandex_iam_service_account_static_access_key.worker]
}

resource "yandex_storage_bucket" "archives" {
  bucket    = var.bucket_name
  folder_id = var.folder_id
  max_size  = 10 * 1024 * 1024 * 1024
  # При destroy Terraform сначала удаляет архивы из созданного им бакета.
  force_destroy = true

  anonymous_access_flags {
    read        = false
    list        = false
    config_read = false
  }
}

data "archive_file" "worker" {
  type             = "zip"
  output_path      = "${path.module}/.terraform/vvot23-worker.zip"
  output_file_mode = "0644"

  # В ZIP попадают только исходники Cloud Functions и манифесты зависимостей.
  dynamic "source" {
    for_each = toset(["index.js", "download.js", "package.json", "package-lock.json"])
    content {
      filename = source.value
      content  = file("${path.module}/function/${source.value}")
    }
  }
}

resource "yandex_function" "worker" {
  name               = "${local.prefix}-archiver"
  runtime            = "nodejs22"
  entrypoint         = "index.handler"
  memory             = 256
  execution_timeout  = 600
  service_account_id = yandex_iam_service_account.accounts["worker"].id
  user_hash          = data.archive_file.worker.output_sha256

  content {
    zip_filename = data.archive_file.worker.output_path
  }

  environment = {
    ARCHIVE_BUCKET    = yandex_storage_bucket.archives.bucket
    ARCHIVE_TABLE     = aws_dynamodb_table.archives.name
    YDB_ENDPOINT      = yandex_ydb_database_serverless.archives.document_api_endpoint
    YDB_ACCESS_KEY_ID = yandex_iam_service_account_static_access_key.worker.access_key
    YDB_SECRET_KEY    = yandex_iam_service_account_static_access_key.worker.secret_key
  }

  depends_on = [yandex_resourcemanager_folder_iam_member.roles["worker-storage"]]
}

resource "yandex_function_trigger" "tasks" {
  name = "${local.prefix}-tasks-trigger"

  message_queue {
    queue_id           = yandex_message_queue.tasks.arn
    service_account_id = yandex_iam_service_account.accounts["trigger"].id
    batch_cutoff       = 0
    batch_size         = 1
  }

  function {
    id                 = yandex_function.worker.id
    service_account_id = yandex_iam_service_account.accounts["trigger"].id
  }

  depends_on = [yandex_resourcemanager_folder_iam_member.roles["trigger-queue"], yandex_resourcemanager_folder_iam_member.roles["trigger-function"]]
}

resource "yandex_api_gateway" "archive" {
  name = "${local.prefix}-api"
  spec = templatefile("${path.module}/openapi.yaml", {
    service_account_id = yandex_iam_service_account.accounts["gateway"].id
    queue_url          = yandex_message_queue.tasks.id
    database_path      = yandex_ydb_database_serverless.archives.database_path
    table_name         = aws_dynamodb_table.archives.name
    bucket_name        = yandex_storage_bucket.archives.bucket
  })

  depends_on = [yandex_resourcemanager_folder_iam_member.roles["gateway-queue"], yandex_resourcemanager_folder_iam_member.roles["gateway-storage"], yandex_resourcemanager_folder_iam_member.roles["gateway-ydb"]]
}
