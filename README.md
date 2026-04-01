## ✨ Principais Funcionalidades  

## 📂 Gestão de Pastas e Setores  

Criação automática de setores com estruturas públicas e privadas  
Suporte a pastas colaborativas diretamente na raiz  
Sistema de lixeira invisível na rede (proteção contra exclusões acidentais)  
Restauração em massa de arquivos mantendo a estrutura original  

## 🛡️ Permissões e Segurança  

Gerenciamento automático de permissões via ACL  
Definição de gestores com acesso completo aos seus setores  
Auditoria e correção automática de permissões inconsistentes  
Suporte a pastas públicas com acesso guest controlado  

## 📊 Armazenamento e Quotas  

Visualização em tempo real do uso de disco  
Monitoramento baseado em:  
uso físico das pastas (du)  
quotas do kernel (repquota)  
Provisionamento automático de novos discos com suporte a quotas  

## ☁️ Backup e Integração com Nuvem  
 
Backups criptografados utilizando Rclone  
Controle de taxa de transferência para evitar bloqueios de API  
Monitoramento de logs em tempo real com baixo consumo de recursos  

## 🌐 Rede e Infraestrutura  

Compatível com LXC e Proxmox  
Detecção automática do ambiente (container ou hardware físico)  
Interface adaptável ao tamanho do terminal  


## 🛠️ Tecnologias Utilizadas  

Samba — compartilhamento de arquivos em rede  
Rclone — integração com armazenamento em nuvem  
ACL & Quotas — controle de acesso e limites de armazenamento  
Bash Script — automação e interface interativa  
Rsync — transferência segura de dados  

## 🎯 Objetivo do Projeto

Automatizar e padronizar a administração de servidores Samba, reduzindo erros operacionais e simplificando a gestão diária através de uma interface prática em terminal.
