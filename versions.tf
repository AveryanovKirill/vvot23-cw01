terraform {
  required_version = ">= 1.5, < 2.0"

  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "0.250.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "5.100.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "2.8.1"
    }
  }
}

# IAM-токен провайдер читает из переменной окружения YC_TOKEN.
provider "yandex" {
  cloud_id  = var.cloud_id
  folder_id = var.folder_id
  zone      = "ru-central1-a"
}

# Этот провайдер обращается к YDB через совместимый с DynamoDB Document API.
provider "aws" {
  region     = "ru-central1"
  access_key = yandex_iam_service_account_static_access_key.worker.access_key
  secret_key = yandex_iam_service_account_static_access_key.worker.secret_key

  # При первом плане ключ ещё неизвестен. Файл даёт SDK фиктивные значения
  # для инициализации. При создании таблицы используются ключи выше.
  shared_credentials_files    = ["${path.module}/aws-plan-credentials.ini"]
  profile                     = "vvot23-plan"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true

  endpoints {
    dynamodb = yandex_ydb_database_serverless.archives.document_api_endpoint
  }
}
