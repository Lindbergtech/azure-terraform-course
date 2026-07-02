output "container_app_fqdn" {
  description = "Public FQDN of the URL shortener Container App. curl https://<fqdn> once apply finishes."
  value       = azapi_resource.app.output.properties.configuration.ingress.fqdn
}
