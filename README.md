# Система архивирования файлов

Контрольная работа № 1, вариант 23. Сервис принимает задания по HTTP, скачивает исходные файлы и сохраняет ZIP-архивы в Yandex Object Storage. Метаданные хранятся в YDB.

## Развёртывание

Требуются Terraform (`>= 1.5, < 2.0`), IAM-токен Yandex Cloud и права на создание ресурсов и назначение ролей в целевом каталоге. Файл `terraform.tfvars` создаётся на основе `terraform.tfvars.example`.

| Переменная | Значение |
| --- | --- |
| `cloud_id` | Идентификатор облака |
| `folder_id` | Идентификатор целевого каталога |
| `bucket_name` | Глобально уникальное имя бакета с префиксом `vvot23-` |

Команды выполняются из корня репозитория. В примере для PowerShell токен получается через Yandex Cloud CLI и передаётся Terraform в переменной `YC_TOKEN`.

```powershell
$env:YC_TOKEN = yc iam create-token
terraform init
terraform validate
terraform apply
terraform output -raw api_url
```

## API

| Метод и путь | Назначение |
| --- | --- |
| `POST /tasks` | Принять задание с полями `name` и `url` |
| `GET /archives` | Получить список архивов |
| `GET /archives/{key}` | Получить метаданные архива |
| `GET /download/{key}` | Скачать ZIP-архив |

Спецификация доступна в [`openapi.yaml`](openapi.yaml). Максимальный размер исходного файла — 32 МиБ, ZIP-архива — 2 МБ.

## Удаление ресурсов

```powershell
terraform destroy
```
