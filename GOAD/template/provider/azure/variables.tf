variable "location" {
  type    = string
  default = "{{config.get_value('azure', 'az_location', 'westeurope')}}"
}

# default size : 2cpu / 4GB
variable "size" {
  type    = string
  default = "Standard_B1ms"
}

variable "username" {
  type    = string
  default = "goadmin"
}

variable "password" {
  description = "Password of the windows virtual machine admin user"
  type    = string
  default = "goadmin"
}

variable "jumpbox_username" {
  type    = string
  default = "goad"
}

# jumpbox_location : région du jumpbox, distincte de var.location (région des
# DC). Par défaut identique à var.location (comportement GOAD standard,
# jumpbox dans le même VNet que les DC). Surchargeable via TF_VAR_jumpbox_location,
# utilisé par ce lab hybride pour placer le jumpbox dans une région à part dès
# la création (cf. GOAD/docs/amont-changes.md), le quota Azure de la région
# des DC étant déjà saturé par dc01+dc02+srv02.
variable "jumpbox_location" {
  type    = string
  default = "{{config.get_value('azure', 'az_location', 'westeurope')}}"
}

# jumpbox_allowed_ip : source autorisée sur le port SSH du jumpbox. Par défaut
# "*", comme la règle SSH du subnet principal (cf. network.tf). Surchargeable
# via TF_VAR_jumpbox_allowed_ip.
variable "jumpbox_allowed_ip" {
  type    = string
  default = "*"
}
