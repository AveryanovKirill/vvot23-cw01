variable "cloud_id" {
  type        = string
  description = "Идентификатор облака Yandex Cloud."
}

variable "folder_id" {
  type        = string
  description = "Идентификатор каталога для развёртывания."
}

variable "bucket_name" {
  type        = string
  description = "Глобально уникальное имя нового бакета с префиксом vvot23-."

  validation {
    condition     = can(regex("^vvot23-[a-z0-9-]*[a-z0-9]$", var.bucket_name)) && length(var.bucket_name) <= 63
    error_message = "Укажите имя бакета с префиксом vvot23-, до 63 символов. После префикса допустимы строчные латинские буквы, цифры и дефисы."
  }
}
