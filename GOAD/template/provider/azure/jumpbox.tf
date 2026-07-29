resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Réseau dédié au jumpbox, dans var.jumpbox_location (peut différer de la
# région des DC, cf. variables.tf). CIDR 10.201.0.0/16 : ne chevauche pas le
# subnet des DC ({{ip_range}}.0/24).
resource "azurerm_virtual_network" "jumpbox_network" {
  name                = "{{lab_name}}-jumpbox-network"
  address_space       = ["10.201.0.0/16"]
  location            = var.jumpbox_location
  resource_group_name = azurerm_resource_group.resource_group.name
}

resource "azurerm_subnet" "jumpbox_subnet" {
  name                 = "{{lab_name}}-jumpbox-subnet"
  resource_group_name  = azurerm_resource_group.resource_group.name
  virtual_network_name = azurerm_virtual_network.jumpbox_network.name
  address_prefixes     = ["10.201.1.0/24"]
}

# Un subnet créé from scratch n'a aucun NSG associé -> DenyAllInBound
# implicite bloque tout SSH : règle explicite requise dès la création.
resource "azurerm_network_security_group" "jumpbox_nsg" {
  name                = "{{lab_name}}-jumpbox-nsg"
  location            = var.jumpbox_location
  resource_group_name = azurerm_resource_group.resource_group.name

  security_rule {
    name                        = "AllowSSHInbound"
    priority                    = 100
    direction                   = "Inbound"
    access                      = "Allow"
    protocol                    = "Tcp"
    source_port_range           = "*"
    destination_port_range      = "22"
    source_address_prefix       = var.jumpbox_allowed_ip
    destination_address_prefix  = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "jumpbox_nsg_association" {
  subnet_id                 = azurerm_subnet.jumpbox_subnet.id
  network_security_group_id = azurerm_network_security_group.jumpbox_nsg.id
}

# Peering bidirectionnel avec le VNet des DC : nécessaire dès la création
# puisque le provisioning Ansible de GOAD (juste après cet apply) se connecte
# depuis le jumpbox vers dc01 en WinRM. Le trafic inter-VNet peeré est déjà
# couvert par la règle par défaut AllowVnetInBound (tag VirtualNetwork), sans
# règle NSG supplémentaire.
resource "azurerm_virtual_network_peering" "jumpbox_to_main" {
  name                         = "peer-jumpbox-to-main"
  resource_group_name          = azurerm_resource_group.resource_group.name
  virtual_network_name         = azurerm_virtual_network.jumpbox_network.name
  remote_virtual_network_id    = azurerm_virtual_network.virtual_network.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "main_to_jumpbox" {
  name                         = "peer-main-to-jumpbox"
  resource_group_name          = azurerm_resource_group.resource_group.name
  virtual_network_name         = azurerm_virtual_network.virtual_network.name
  remote_virtual_network_id    = azurerm_virtual_network.jumpbox_network.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_public_ip" "ubuntu_public_ip" {
  name                = "ubuntu-public-ip"
  location            = var.jumpbox_location
  resource_group_name = azurerm_resource_group.resource_group.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "ubuntu_jumbox_nic" {
  name                = "ubuntu-jumbox-nic"
  location            = var.jumpbox_location
  resource_group_name = azurerm_resource_group.resource_group.name

  ip_configuration {
    name                          = "ubuntu-jumbox-nic-ipconfig"
    subnet_id                     = azurerm_subnet.jumpbox_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.201.1.100"
    public_ip_address_id          = azurerm_public_ip.ubuntu_public_ip.id
  }
}

resource "azurerm_linux_virtual_machine" "jumpbox" {
  name                = "ubuntu-jumpbox"
  resource_group_name = azurerm_resource_group.resource_group.name
  location            = var.jumpbox_location
  size                = var.size
  admin_username      = var.jumpbox_username
  network_interface_ids = [
    azurerm_network_interface.ubuntu_jumbox_nic.id,
  ]

  disable_password_authentication = true

  admin_ssh_key {
    username   = var.jumpbox_username
    public_key = tls_private_key.ssh.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  provisioner "local-exec" {
    command = "echo '${tls_private_key.ssh.private_key_pem}' > ../ssh_keys/ubuntu-jumpbox.pem && chmod 600 ../ssh_keys/ubuntu-jumpbox.pem"
  }
}
