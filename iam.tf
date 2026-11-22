locals {
  prefix     = "vvot23"
  table_name = "archives"

  # У каждого компонента своя учётная запись и только необходимые ему роли.
  folder_roles = {
    "gateway-queue"    = { account = "gateway", role = "ymq.writer" }
    "gateway-storage"  = { account = "gateway", role = "storage.viewer" }
    "gateway-ydb"      = { account = "gateway", role = "ydb.viewer" }
    "trigger-queue"    = { account = "trigger", role = "ymq.reader" }
    "trigger-function" = { account = "trigger", role = "functions.functionInvoker" }
    "worker-storage"   = { account = "worker", role = "storage.uploader" }
    "worker-ydb"       = { account = "worker", role = "ydb.editor" }
    "terraform-queue"  = { account = "queue-admin", role = "ymq.admin" }
  }
}

resource "yandex_iam_service_account" "accounts" {
  for_each = toset(["gateway", "trigger", "worker", "queue-admin"])
  name     = "${local.prefix}-${each.key}"
}

resource "yandex_resourcemanager_folder_iam_member" "roles" {
  for_each  = local.folder_roles
  folder_id = var.folder_id
  role      = each.value.role
  member    = "serviceAccount:${yandex_iam_service_account.accounts[each.value.account].id}"

  # Очередь и документная таблица должны увидеть новые роли при первом apply.
  sleep_after = contains(["terraform-queue", "worker-ydb"], each.key) ? 30 : 0
}

resource "yandex_iam_service_account_static_access_key" "queue_admin" {
  service_account_id = yandex_iam_service_account.accounts["queue-admin"].id
  description        = "${local.prefix}-queue-management"

  depends_on = [yandex_resourcemanager_folder_iam_member.roles["terraform-queue"]]
}

resource "yandex_iam_service_account_static_access_key" "worker" {
  service_account_id = yandex_iam_service_account.accounts["worker"].id
  description        = "${local.prefix}-document-api"

  depends_on = [yandex_resourcemanager_folder_iam_member.roles["worker-ydb"]]
}
