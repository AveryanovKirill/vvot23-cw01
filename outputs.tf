output "api_url" {
  description = "Служебный адрес API-шлюза."
  value       = "https://${yandex_api_gateway.archive.domain}"
}
