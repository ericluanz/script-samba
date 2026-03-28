#!/bin/bash
# ==============================================================================
# Gerenciamento Shell
# ==============================================================================

# --- CORES E FORMATAÇÃO ---
C_VERDE='\033[1;32m'
C_AMARELO='\033[1;33m'
C_VERMELHO='\033[1;31m'
C_AZUL='\033[1;34m'
C_CIANO='\033[1;36m'
C_RESET='\033[0m'

msg_info()  { echo -e "${C_AZUL}[INFO]${C_RESET} $1"; }
msg_ok()    { echo -e "${C_VERDE}[ OK ]${C_RESET} $1"; }
msg_erro()  { echo -e "${C_VERMELHO}[ERRO]${C_RESET} $1"; }
msg_aviso() { echo -e "${C_AMARELO}[AVISO]${C_RESET} $1"; }

# --- RESPONSIVIDADE DE TELA ---
get_term_width() {
    local c=$(tput cols 2>/dev/null)
    if [[ -z "$c" || ! "$c" =~ ^[0-9]+$ ]]; then
        c=$(stty size 2>/dev/null | awk '{print $2}')
    fi
    [[ -z "$c" || ! "$c" =~ ^[0-9]+$ ]] && c=115 # Fallback de segurança
    echo "$c"
}

get_term_height() {
    local h=$(tput lines 2>/dev/null)
    if [[ -z "$h" || ! "$h" =~ ^[0-9]+$ ]]; then
        h=$(stty size 2>/dev/null | awk '{print $1}')
    fi
    [[ -z "$h" || ! "$h" =~ ^[0-9]+$ ]] && h=30 # Fallback de segurança
    echo "$h"
}

linha() {
    local w=$(get_term_width)
    printf "${C_CIANO}%*s${C_RESET}\n" "$w" "" | tr ' ' '='
}

linha_traco() {
    local w=$(get_term_width)
    printf "${C_CIANO}%*s${C_RESET}\n" "$w" "" | tr ' ' '-'
}

center_text() {
    local text="$1"
    local color="$2"
    local w=$(get_term_width)
    local padding=$(( (w - ${#text}) / 2 ))
    [[ $padding -lt 0 ]] && padding=0
    printf "%*s%b%s%b\n" $padding "" "$color" "$text" "$C_RESET"
}

header() {
    clear
    local w=$(get_term_width)
    local ip_server=$(hostname -I 2>/dev/null | awk '{print $1}')
    local ip_str="IP do Servidor: ${ip_server:-Desconhecido}"
    
    linha
    center_text "SISTEMA DE GESTÃO DE ARQUIVOS - V24.1" "$C_VERDE"
    center_text "By: devalldev" "$C_AMARELO"
    
    local pad3=$(( (w - ${#ip_str}) / 2 ))
    [[ $pad3 -lt 0 ]] && pad3=0
    printf "%*s%bIP do Servidor: %b%s%b\n" $pad3 "" "$C_AZUL" "$C_VERDE" "${ip_server:-Desconhecido}" "$C_RESET"
    linha
    echo ""
}

# --- TRAVA DE SEGURANÇA ROOT ---
[[ "$EUID" -ne 0 ]] && header && msg_erro "Este script precisa de permissões administrativas. Execute com 'sudo ./samba.sh'" && echo "" && exit 1

# --- CHECAGEM E INSTALAÇÃO DE DEPENDÊNCIAS ---
verificar_dependencias() {
    local dependencias=(samba acl quota quotatool smbclient parted tree rclone cron rsync)
    local precisa_instalar=0

    for pkg in "${dependencias[@]}"; do
        if ! dpkg -l | grep -qw "$pkg"; then precisa_instalar=1; break; fi
    done

    if [ "$precisa_instalar" -eq 1 ]; then
        header
        msg_aviso "Servidor novo detectado! Preparando o ambiente..."
        msg_info "Instalando dependências base (Samba, ACL, Quotas, Rclone, Cron, Rsync)..."
        apt-get update &> /dev/null
        apt-get install -y "${dependencias[@]}" &> /dev/null
        systemctl enable smbd cron &> /dev/null
        systemctl start smbd cron &> /dev/null
        msg_ok "Dependências instaladas com sucesso!"
        sleep 2
    fi
}

# --- AJUSTE GLOBAL DE REDE (GUEST OK) ---
garantir_samba_guest() {
    if grep -q "\[global\]" /etc/samba/smb.conf && ! grep -q "map to guest" /etc/samba/smb.conf; then
        msg_info "Ajustando diretivas globais do Linux para permitir Pastas Públicas..."
        sed -i '/\[global\]/a \ \ \ \ map to guest = bad user' /etc/samba/smb.conf
        systemctl restart smbd
    fi
}

# --- AUTO-PROVISIONAMENTO DE QUOTAS ---
garantir_motor_quotas() {
    local pm=$(df -P /mnt/dados 2>/dev/null | tail -n 1 | awk '{print $6}')
    [[ -z "$pm" ]] && pm="/"
    
    if ! awk -v p="$pm" '$1 !~ /^#/ && $2 == p {print $4}' /etc/fstab | grep -qE "grpquota|jqfmt"; then
        msg_info "Motor de Quotas ausente em '$pm'. Auto-configurando fstab..."
        cp /etc/fstab /etc/fstab.bak_quota_$(date +%F_%H-%M)
        local fstab_line=$(awk -v p="$pm" '$1 !~ /^#/ && $2 == p {print $0}' /etc/fstab | head -n 1)
        if [[ -n "$fstab_line" ]]; then
            local opt_old=$(echo "$fstab_line" | awk '{print $4}')
            local opt_new="${opt_old},usrquota,grpquota"
            local pm_sed=$(echo "$pm" | sed 's/\//\\\//g')
            sed -i "/^[[:space:]]*[^#].*[[:space:]]$pm_sed[[:space:]]/s@$opt_old@$opt_new@" /etc/fstab
            mount -o remount "$pm" 2>/dev/null
            quotacheck -cumg "$pm" 2>/dev/null
            quotaon -v "$pm" 2>/dev/null
            msg_ok "Fstab configurado. O servidor de Quotas agora está ativo."
            sleep 2
        fi
    else
        quotaon "$pm" 2>/dev/null
    fi
}

# --- FUNÇÕES DE APOIO ---
listar_setores_samba() {
    grep -E '^\[.*\]' /etc/samba/smb.conf | grep -vE '\[global\]|\[printers\]|\[print\$\]' | tr -d '[]' | sort -u
}

obter_info_quota_raw() {
    local s_lower=$1
    local s_upper=$(echo "$s_lower" | tr '[:lower:]' '[:upper:]')
    local pm=$(df -P /mnt/dados 2>/dev/null | tail -n 1 | awk '{print $6}')
    [[ -z "$pm" ]] && pm="/"
    
    local u=0; local l=0
    
    # 1. BUSCA O LIMITE (Teto de Quota) via Banco do Kernel
    local rep_out=$(repquota -g -w "$pm" 2>/dev/null | awk -v grp="$s_lower" '$1 == grp {print $5}')
    if [[ -n "$rep_out" ]]; then
        l="$rep_out"
    else
        local q_out=$(quota -g "$s_lower" -w -v 2>/dev/null | grep -v "Disk quotas" | grep -v "Filesystem" | tail -n 1)
        [[ -n "$q_out" ]] && l=$(echo "$q_out" | awk '{print $4}')
    fi
    
    # 2. BUSCA O USO REAL FÍSICO (Ignora dono, soma os bytes totais da pasta)
    local pasta="/mnt/dados/$s_upper"
    if [[ -d "$pasta" ]]; then
        u=$(du -sk "$pasta" 2>/dev/null | awk '{print $1}')
    fi
    
    u=${u//\*/}; l=${l//\*/}
    [[ ! "$u" =~ ^[0-9]+$ ]] && u=0
    [[ ! "$l" =~ ^[0-9]+$ ]] && l=0
    
    echo "$u $l"
}

selecionar_setor() {
    SETOR_ESCOLHIDO=""
    local setores=($(listar_setores_samba))
    if [ ${#setores[@]} -eq 0 ]; then msg_aviso "Nenhum setor cadastrado no momento."; sleep 2; return 1; fi
    
    echo -e "${C_AMARELO}Setores disponíveis:${C_RESET}"
    local w=$(get_term_width)
    local base_len=68 # Espaço consumido pela estrutura fixa visual
    local max_mem=$(( w - base_len ))
    [[ $max_mem -lt 5 ]] && max_mem=5
    
    for i in "${!setores[@]}"; do
        local s=${setores[$i]}; local s_lower=$(echo "$s" | tr '[:upper:]' '[:lower:]')
        read usado limit <<< $(obter_info_quota_raw "$s_lower")
        
        local uso_gb=$(LC_ALL=C awk "BEGIN {printf \"%.1f\", $usado/1048576}" | sed 's/\./,/')
        local txt_quota="Quota: Ilimitada"; local color_q="${C_VERDE}"
        if [[ "$limit" -gt 0 ]]; then
            local lim_gb=$((limit / 1048576)); local porcentagem=$(( (usado * 100) / limit ))
            txt_quota="Quota: ${lim_gb}GB"; color_q="${C_VERMELHO}"; local txt_usado="Usado: ${uso_gb}GB (${porcentagem}%)"
        else local txt_usado="Usado: ${uso_gb}GB"; fi
        
        local idx_pad=$(printf "%2s" "$i")
        local pad_nome=$(printf "%-15s" "$s")
        local pad_quota=$(printf "%-18s" "[$txt_quota]")
        local pad_usado=$(printf "%-26s" "[$txt_usado]")
        
        printf " [%b%s%b] [ %b%s%b ] - %b%s%b | %b%s%b\n" "$C_AZUL" "$idx_pad" "$C_RESET" "$C_VERDE" "$pad_nome" "$C_RESET" "$color_q" "$pad_quota" "$C_RESET" "$C_AMARELO" "$pad_usado" "$C_RESET"
    done
    linha_traco
    read -r -p "Selecione o número do setor (ou V para voltar): " s_idx
    [[ "$s_idx" =~ ^[Vv]$ ]] && return 1
    if ! [[ "$s_idx" =~ ^[0-9]+$ ]] || [ "$s_idx" -ge "${#setores[@]}" ]; then msg_erro "Opção inválida!"; sleep 2; return 1; fi
    SETOR_ESCOLHIDO="${setores[$s_idx]}"; return 0
}

garantir_usuario_samba() {
    local nome_user=$1
    if ! id "$nome_user" &>/dev/null; then
        msg_info "Criando usuário no Linux: '$nome_user'..."
        useradd -M -s /usr/sbin/nologin "$nome_user"
        (echo; echo) | smbpasswd -a "$nome_user" >/dev/null 2>&1
        echo -e "${C_AMARELO}>>> Defina a senha do Samba para: ${C_VERDE}$nome_user${C_RESET}"
        smbpasswd "$nome_user"
        msg_ok "Usuário '$nome_user' pronto."
    fi
}

# ==============================================================================
# MÓDULOS DE GESTÃO
# ==============================================================================
menu_usuarios() {
    while true; do
        header; echo -e "${C_AMARELO}--- 👤 GESTÃO DE USUÁRIOS ---${C_RESET}\n"
        echo " 1) Listar Usuários do Sistema"
        echo " 2) Criar Novo Usuário"
        echo " 3) Alterar Senha de Usuário"
        echo " 4) Deletar Usuário (Cortar Acesso)"
        echo " V) Voltar ao Menu Principal"
        linha_traco; read -r -p "Escolha: " opt_u
        
        case $opt_u in
            1)
                echo -e "\n${C_AZUL}Usuários Reais do Sistema (UID >= 1000):${C_RESET}"
                awk -F: '$3 >= 1000 && $1 != "nobody" {print " - " $1}' /etc/passwd
                echo ""; read -r -p "Pressione Enter para voltar..." 
                ;;
            2) 
                read -r -p "Digite o login (Ex: eduardo.ferro): " n_u
                [[ -n "$n_u" ]] && garantir_usuario_samba "$(echo "$n_u" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
                sleep 2 
                ;;
            3) 
                read -r -p "Digite o login do usuário para alterar a senha: " a_u
                id "$a_u" &>/dev/null && smbpasswd "$a_u" && msg_ok "Senha alterada!" || msg_erro "Usuário não encontrado."
                sleep 2 
                ;;
            4) 
                read -r -p "Digite o login do usuário para DELETAR: " d_u
                if id "$d_u" &>/dev/null; then
                    echo -e "\n${C_VERMELHO}>>> ATENÇÃO: Isso cortará totalmente o acesso de '$d_u'.${C_RESET}"
                    read -r -p "Tem certeza que deseja continuar? (SIM/NAO): " conf
                    if [[ "$conf" == "SIM" ]]; then userdel "$d_u"; smbpasswd -x "$d_u" &>/dev/null; msg_ok "Usuário excluído!"; else msg_aviso "Operação cancelada."; fi
                else msg_erro "Usuário não existe no sistema."; fi
                sleep 2 
                ;;
            [Vv]) return ;;
            *) msg_erro "Opção inválida!"; sleep 1 ;;
        esac
    done
}

menu_setores() {
    while true; do
        header; echo -e "${C_AMARELO}--- 📁 GESTÃO DE SETORES ---${C_RESET}\n"
        echo "  1) Listar Setores e Espaço Usado (Dashboard Visual)"
        echo "  2) Criar Novo Setor (Estrutura Blindada ou Pasta Solta)"
        echo "  3) Alterar Espaço (Quota) de um Setor"
        echo "  4) Criar Pasta Pública GERAL (Acesso Livre a Todos)"
        echo "  5) Excluir um Setor"
        echo "  6) Visualizar Estrutura de Pastas (Tree Map)"
        echo "  7) 🛡️ Filtrar/Bloquear Tipos de Arquivos (Ex: .mp3, .exe)"
        echo "  8) 🗑️ Esvaziar Lixeiras do Servidor (Apagar Arquivos)"
        echo "  9) ⚡ Otimizar Disco e Devolver Espaço ao Storage (FSTRIM)"
        echo " 10) ♻️ Explorar e Restaurar Arquivos da Lixeira"
        echo "  V) Voltar ao Menu Principal"
        linha_traco; read -r -p "Escolha: " opt_s
        
        case $opt_s in
            1)
                header
                echo -e "${C_AMARELO}⏳ Lendo o disco e calculando o tamanho físico real das pastas...${C_RESET}"
                echo -e "${C_CIANO}Isso pode levar alguns segundos em setores com muitos arquivos. Aguarde!${C_RESET}\n"
                
                GLOBAL_TOTAL_QUOTA=0; GLOBAL_TOTAL_USADO=0; local setores=($(listar_setores_samba))
                local w=$(get_term_width)
                local base_len=68 
                local max_mem=$(( w - base_len ))
                [[ $max_mem -lt 5 ]] && max_mem=5
                
                header; echo -e "${C_AZUL}Dashboard de Setores Configurados:${C_RESET}"
                if [ ${#setores[@]} -eq 0 ]; then 
                    msg_aviso "Nenhum setor encontrado."
                else
                    for s in "${setores[@]}"; do
                        local sl=$(echo "$s" | tr '[:upper:]' '[:lower:]'); local mem=$(grep "^$sl:" /etc/group | cut -d: -f4)
                        read u l <<< $(obter_info_quota_raw "$sl"); GLOBAL_TOTAL_USADO=$((GLOBAL_TOTAL_USADO + u)); [[ "$l" -gt 0 ]] && GLOBAL_TOTAL_QUOTA=$((GLOBAL_TOTAL_QUOTA + l))
                        local ug=$(LC_ALL=C awk "BEGIN {printf \"%.1f\", $u/1048576}" | sed 's/\./,/')
                        local tq="Quota: Ilimitada"; local color_q="${C_VERDE}"
                        if [[ "$l" -gt 0 ]]; then local lg=$((l / 1048576)); local p=$(( (u * 100) / l )); tq="Quota: ${lg}GB"; color_q="${C_VERMELHO}"; local tu="Usado: ${ug}GB ($p%)"
                        else local tu="Usado: ${ug}GB"; fi
                        
                        local mem_str="${mem:-Acesso Geral / Nenhum}"
                        if [[ ${#mem_str} -gt $max_mem ]]; then
                            mem_str="${mem_str:0:$((max_mem - 3))}..."
                        fi
                        
                        local pad_nome=$(printf "%-15s" "$s")
                        local pad_quota=$(printf "%-18s" "[$tq]")
                        local pad_usado=$(printf "%-26s" "[$tu]")
                        
                        printf " [ %b%s%b ] - %b%s%b | %b%s%b -> Usuários: %b%s%b\n" "$C_VERDE" "$pad_nome" "$C_RESET" "$color_q" "$pad_quota" "$C_RESET" "$C_AMARELO" "$pad_usado" "$C_RESET" "$C_AMARELO" "$mem_str" "$C_RESET"
                    done
                    linha_traco
                    tq_txt=$(LC_ALL=C awk "BEGIN {printf \"%.1f GB\", $GLOBAL_TOTAL_QUOTA/1048576}" | sed 's/\./,/'); tu_txt=$(LC_ALL=C awk "BEGIN {printf \"%.1f GB\", $GLOBAL_TOTAL_USADO/1048576}" | sed 's/\./,/')
                    dl_mb=$(df -m /mnt/dados | awk 'NR==2 {print $4}' 2>/dev/null); txt_livre="0,0 GB"
                    [[ "$dl_mb" =~ ^[0-9]+$ ]] && txt_livre=$(LC_ALL=C awk "BEGIN {printf \"%.1f GB\", $dl_mb/1024}" | sed 's/\./,/')
                    echo -e " ${C_AMARELO}Armazenamento Total Utilizado    : ${C_VERDE}${tu_txt}${C_RESET}"
                    echo -e " ${C_AMARELO}Soma Total de Limites Prometidos : ${C_VERMELHO}${tq_txt}${C_RESET}"
                    echo -e " ${C_AMARELO}Espaço Livre Físico (/mnt/dados) : ${C_CIANO}${txt_livre}${C_RESET}"
                fi; echo ""; read -p "Pressione Enter para voltar..." 
                ;;
            2)
                read -r -p "Nome do Novo Setor (Ex: TI, RH): " sn; [[ -z "$sn" ]] && continue
                local sl=$(echo "$sn" | tr '[:upper:]' '[:lower:]' | tr -d ' '); local su=$(echo "$sn" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
                
                if grep -iq "^\[$su\]$" /etc/samba/smb.conf; then
                    msg_erro "O setor '$su' já existe no sistema!"
                    sleep 2; continue
                fi

                local base_dir="/mnt/dados/$su"
                
                echo -e "\n${C_AMARELO}Qual o estilo deste setor?${C_RESET}"
                echo " 1) ESTRUTURA BLINDADA (Cria a subpasta PUBLICO separada e restrita)"
                echo " 2) PASTA SOLTA (Sem subpastas. Todo mundo do grupo joga os arquivos direto na raiz)"
                read -r -p "Sua escolha (1 ou 2): " opt_estilo
                
                groupadd "$sl" &>/dev/null
                
                if [[ "$opt_estilo" == "2" ]]; then
                    msg_info "Criando Pasta Solta em $base_dir..."
                    mkdir -p "$base_dir"
                    mkdir -p "$base_dir/.lixeira"
                    chown root:"$sl" "$base_dir"
                    chown root:"$sl" "$base_dir/.lixeira"
                    
                    chmod 2770 "$base_dir"
                    chmod 1777 "$base_dir/.lixeira"
                    setfacl -d -m g:"$sl":rwx "$base_dir" 2>/dev/null
                    
                    touch "$base_dir/.gestores"
                    touch "$base_dir/.excecoes"
                else
                    echo -e "\n${C_AMARELO}Comportamento da pasta PUBLICO deste setor:${C_RESET}"
                    echo " 1) PADRÃO (Dono Apaga): Todos salvam, mas só o dono pode apagar."
                    echo " 2) COLABORAÇÃO (Todos Apagam): Qualquer membro apaga qualquer arquivo."
                    read -r -p "Sua escolha (Enter para Padrão 1): " opt_pub_comportamento
                    
                    msg_info "Criando estrutura blindada em $base_dir..."
                    mkdir -p "$base_dir/PUBLICO"
                    mkdir -p "$base_dir/.lixeira"
                    
                    chmod 755 "$base_dir"
                    chown root:"$sl" "$base_dir/PUBLICO"
                    chown root:"$sl" "$base_dir/.lixeira"
                    
                    if [[ "$opt_pub_comportamento" == "2" ]]; then
                        chmod 2770 "$base_dir/PUBLICO"
                        setfacl -d -m g:"$sl":rwx "$base_dir/PUBLICO" 2>/dev/null
                    else
                        chmod 1770 "$base_dir/PUBLICO"
                    fi
                    chmod 1777 "$base_dir/.lixeira"
                    
                    touch "$base_dir/.gestores"
                    touch "$base_dir/.excecoes"
                fi

                cp /etc/samba/smb.conf /etc/samba/smb.conf.bak_$(date +%F_%T)
                cat <<EOF >> /etc/samba/smb.conf

[$su]
   path = $base_dir
   browseable = yes
   read only = no
   valid users = @$sl
   force group = $sl
   create mask = 0660
   directory mask = 0770
   hide unreadable = yes
   veto files = /.gestores/.excecoes/.lixeira/
   vfs objects = recycle
   recycle:repository = .lixeira
   recycle:keeptree = yes
   recycle:versions = yes
EOF
                systemctl restart smbd; msg_ok "Setor '$su' criado com sucesso!"; sleep 3 
                ;;
            3) 
                selecionar_setor || continue; sl=$(echo "$SETOR_ESCOLHIDO" | tr '[:upper:]' '[:lower:]')
                echo ""
                read -p "Novo limite em GB (0 para Ilimitado): " lg
                if [[ "$lg" =~ ^[0-9]+$ ]]; then
                    local pm=$(df -P /mnt/dados 2>/dev/null | tail -n 1 | awk '{print $6}')
                    [[ -z "$pm" ]] && pm="/"
                    setquota -g "$sl" 0 $(( lg * 1048576 )) 0 0 "$pm" 2>/dev/null && msg_ok "Quota atualizada!" || msg_erro "Falha ao gravar Quota na base."
                else msg_erro "Valor inválido."; fi
                sleep 2 
                ;;
            4)
                read -r -p "Nome da Pasta Pública Geral (Ex: PUBLICO): " pub_nome
                [[ -z "$pub_nome" ]] && continue
                local p_lower=$(echo "$pub_nome" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
                local p_upper=$(echo "$pub_nome" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
                
                if grep -iq "^\[$p_upper\]$" /etc/samba/smb.conf; then
                    msg_erro "A pasta '$p_upper' já existe no sistema!"
                    sleep 2; continue
                fi
                
                echo -e "\n${C_AMARELO}Comportamento da exclusão de arquivos nesta Pasta Pública Geral:${C_RESET}"
                echo " 1) PADRÃO (Dono Apaga): Todos salvam, mas só o dono (quem criou) pode apagar."
                echo " 2) COLABORAÇÃO (Todos Apagam): Qualquer pessoa na rede pode apagar qualquer arquivo."
                read -r -p "Sua escolha (Enter para Padrão 1): " opt_pub_geral
                
                local base_dir="/mnt/dados/$p_upper"
                msg_info "Criando Pasta Pública de Acesso Livre em $base_dir..."
                
                groupadd "$p_lower" &>/dev/null
                mkdir -p "$base_dir"
                mkdir -p "$base_dir/.lixeira"
                
                chown -R nobody:"$p_lower" "$base_dir"
                chmod 2777 "$base_dir"
                chmod 2777 "$base_dir/.lixeira"
                
                touch "$base_dir/.gestores"
                touch "$base_dir/.excecoes"
                chown nobody:"$p_lower" "$base_dir/.gestores" "$base_dir/.excecoes"
                
                cp /etc/samba/smb.conf /etc/samba/smb.conf.bak_$(date +%F_%T)
                
                cat <<EOF >> /etc/samba/smb.conf

[$p_upper]
   path = $base_dir
   browseable = yes
   read only = no
   guest ok = yes
   guest only = yes
   force user = nobody
   force group = $p_lower
   create mask = 0666
   directory mask = 0777
   veto files = /.gestores/.excecoes/.lixeira/
   vfs objects = recycle
   recycle:repository = .lixeira
   recycle:keeptree = yes
   recycle:versions = yes
EOF
                systemctl restart smbd
                msg_ok "Pasta Pública Geral '$p_upper' criada com acesso anônimo habilitado!"
                sleep 4
                ;;
            5)
                selecionar_setor || continue
                local s_upper="$SETOR_ESCOLHIDO"
                local s_lower=$(echo "$s_upper" | tr '[:upper:]' '[:lower:]')
                local base_dir="/mnt/dados/$s_upper"

                echo -e "\n${C_VERMELHO}>>> ATENÇÃO: Você está prestes a excluir o setor '$s_upper' da rede. <<<${C_RESET}"
                read -r -p "Tem certeza que deseja continuar? (SIM/NAO): " conf_exc
                if [[ "$conf_exc" != "SIM" ]]; then msg_aviso "Operação cancelada."; sleep 2; continue; fi

                msg_info "Removendo configurações do arquivo smb.conf e limpando Quotas..."
                cp /etc/samba/smb.conf /etc/samba/smb.conf.bak_exc_$(date +%s)
                awk -v sec="[$s_upper]" ' /^\[.*\]$/ { if ($0 == sec) { skip = 1 } else { skip = 0 } } !skip { print $0 }' /etc/samba/smb.conf.bak_exc_* | tail -n +1 > /tmp/smb.conf.clean
                cat /tmp/smb.conf.clean > /etc/samba/smb.conf
                
                local pm=$(df -P /mnt/dados 2>/dev/null | tail -n 1 | awk '{print $6}')
                [[ -z "$pm" ]] && pm="/"
                setquota -g "$s_lower" 0 0 0 0 "$pm" 2>/dev/null
                groupdel "$s_lower" 2>/dev/null

                echo -e "\n${C_AMARELO}O que você deseja fazer com os ARQUIVOS que estão na pasta do setor?${C_RESET}"
                echo " 1) APAGAR TUDO (Destruição total e irreversível dos dados)"
                echo " 2) MANTER NO DISCO (Renomeia a pasta para backup e oculta da rede)"
                read -r -p "Sua escolha: " opt_arquivos
                
                if [ "$opt_arquivos" -eq 1 ]; then 
                    rm -rf "$base_dir"
                else 
                    mv "$base_dir" "${base_dir}_BKP_$(date +%F_%H-%M)" 2>/dev/null
                fi
                systemctl restart smbd; msg_ok "Setor excluído com sucesso!"; sleep 3 
                ;;
            6)
                echo -e "\n${C_AZUL}--- MAPA ESTRUTURAL DE PASTAS (TREE) ---${C_RESET}"
                echo " 1) Ver TODO o Servidor (/mnt/dados)"
                echo " 2) Escolher um Setor Específico"
                read -r -p "Escolha: " opt_tree
                
                if [ "$opt_tree" -eq 1 ]; then 
                    echo -e "\n${C_VERDE}Diretório Raiz: /mnt/dados${C_RESET}"
                    tree -d -L 3 -u -C /mnt/dados
                elif [ "$opt_tree" -eq 2 ]; then 
                    selecionar_setor || continue
                    echo -e "\n${C_VERDE}Setor: $SETOR_ESCOLHIDO${C_RESET}"
                    tree -d -L 3 -u -C "/mnt/dados/$SETOR_ESCOLHIDO"
                fi
                echo ""; read -r -p "Pressione Enter para voltar..." 
                ;;
            7)
                selecionar_setor || continue
                local s_upper="$SETOR_ESCOLHIDO"
                echo -e "\n${C_AZUL}--- FILTRO DE ARQUIVOS: $s_upper ---${C_RESET}"
                echo -e "${C_AMARELO}Extensões para BLOQUEAR separadas por espaço (Ex: mp3 mp4 exe)${C_RESET}"
                echo -e "${C_VERDE}Para liberar tudo e remover os bloqueios, digite: 0${C_RESET}"
                read -r -p "Extensões a bloquear: " ext_raw; [[ -z "$ext_raw" ]] && continue
                
                local nova_linha_veto="   veto files = /.gestores/.excecoes/.lixeira/"
                if [[ "$ext_raw" != "0" ]]; then
                    local formatado=""
                    for ext in $ext_raw; do ext="${ext//./}"; formatado="$formatado/*.$ext/"; done
                    nova_linha_veto="   veto files = /.gestores/.excecoes/.lixeira${formatado}"
                fi
                
                msg_info "Injetando regras de bloqueio..."
                awk -v sec="[$s_upper]" -v nv="$nova_linha_veto" '$0 == sec { in_sec=1; print $0; next } /^\[.*\]$/ && $0 != sec { in_sec=0 } in_sec && $1 == "veto" && $2 == "files" { print nv; next } { print $0 }' /etc/samba/smb.conf > /tmp/smb.conf.tmp
                cat /tmp/smb.conf.tmp > /etc/samba/smb.conf
                systemctl restart smbd; msg_ok "Filtro aplicado com sucesso!"; sleep 3 
                ;;
            8) 
                echo -e "\n${C_AZUL}--- 🗑️ ESVAZIAR LIXEIRAS DO SERVIDOR ---${C_RESET}"
                echo " 1) Limpar TODAS as Lixeiras de TODOS os Setores"
                echo " 2) Escolher apenas UM Setor Específico"
                echo " V) Voltar"
                read -r -p "Escolha: " opt_lixo
                
                local pm=$(df -P /mnt/dados 2>/dev/null | tail -n 1 | awk '{print $6}')
                [[ -z "$pm" ]] && pm="/"
                
                if [[ "$opt_lixo" == "1" ]]; then
                    find /mnt/dados -mindepth 2 -type d -name ".lixeira" -exec sh -c 'rm -rf "$1"/*; rm -rf "$1"/.[!.]*' _ {} \; 2>/dev/null
                    quotacheck -cumg "$pm" 2>/dev/null
                    msg_ok "Todas as lixeiras foram esvaziadas!"; sleep 2
                elif [[ "$opt_lixo" == "2" ]]; then
                    selecionar_setor || continue
                    sh -c 'rm -rf "$1"/*; rm -rf "$1"/.[!.]*' _ "/mnt/dados/$SETOR_ESCOLHIDO/.lixeira" 2>/dev/null
                    quotacheck -cumg "$pm" 2>/dev/null
                    msg_ok "Lixeira do setor $SETOR_ESCOLHIDO esvaziada!"; sleep 2
                fi
                ;;
            9) 
                echo -e "\n${C_AZUL}--- ⚡ OTIMIZAR DISCO E DEVOLVER ESPAÇO (FSTRIM) ---${C_RESET}"
                echo -e "${C_VERMELHO}Aviso: Isso pode gerar um pico temporário de I/O no disco.${C_RESET}"
                read -r -p "Iniciar otimização física? (SIM/NAO): " conf_trim
                if [[ "$conf_trim" == "SIM" ]]; then
                    msg_info "Sincronizando descarte de blocos físicos... Aguarde..."
                    local res=$(fstrim -v /mnt/dados 2>&1)
                    msg_ok "Concluído! Retorno: $res"
                fi
                echo ""; read -p "Pressione Enter para voltar..." 
                ;;
            10)
                echo -e "\n${C_AZUL}--- ♻️ EXPLORAR E RESTAURAR DA LIXEIRA ---${C_RESET}"
                selecionar_setor || continue
                local bd="/mnt/dados/$SETOR_ESCOLHIDO"
                local lixo="$bd/.lixeira"
                
                if [ ! -d "$lixo" ] || [ -z "$(ls -A "$lixo" 2>/dev/null)" ]; then
                    msg_aviso "A lixeira do setor $SETOR_ESCOLHIDO está completamente vazia."
                    sleep 2; continue
                fi
                
                echo -e "\n${C_AMARELO}Modo de Restauração:${C_RESET}"
                echo " 1) Buscar e selecionar arquivos específicos para restaurar"
                echo " 2) ☢️  Restaurar TODA a lixeira de uma vez"
                read -r -p "Escolha (ou V para voltar): " opt_res_modo
                [[ "$opt_res_modo" =~ ^[Vv]$ ]] && continue
                
                if [[ "$opt_res_modo" == "2" ]]; then
                    echo -e "\n${C_VERMELHO}>>> ATENÇÃO: Isso moverá TODOS os arquivos apagados de volta para a pasta de uso. <<<${C_RESET}"
                    read -r -p "Tem certeza que deseja restaurar tudo? (SIM/NAO): " conf_res_all
                    if [[ "$conf_res_all" == "SIM" ]]; then
                        msg_info "Restaurando a lixeira inteira... Isso pode demorar dependendo do tamanho. Aguarde!"
                        rsync -a --remove-source-files "$lixo/" "$bd/" 2>/dev/null
                        find "$lixo" -type d -empty -delete 2>/dev/null
                        msg_ok "Restauração total concluída com sucesso!"
                    else
                        msg_aviso "Operação cancelada."
                    fi
                    sleep 3
                    continue
                elif [[ "$opt_res_modo" == "1" ]]; then
                    echo -e "\n${C_AMARELO}DICA: Você pode buscar por nome, extensão (ex: .pdf) ou digitar * para ver tudo.${C_RESET}"
                    read -r -p "Digite o termo de busca: " termo
                    [[ -z "$termo" ]] && continue
                    
                    msg_info "Buscando nos registros apagados..."
                    mapfile -t arquivos_encontrados < <(find "$lixo" -mindepth 1 -type f -iname "*$termo*" 2>/dev/null | head -n 50)
                    
                    if [ ${#arquivos_encontrados[@]} -eq 0 ]; then
                        msg_aviso "Nenhum arquivo encontrado com esse termo."
                        sleep 2; continue
                    fi
                    
                    echo -e "\n${C_VERDE}Resultados encontrados (Máximo 50 exibidos):${C_RESET}"
                    for i in "${!arquivos_encontrados[@]}"; do
                        local item_path="${arquivos_encontrados[$i]}"
                        local caminho_relativo="${item_path#$lixo/}"
                        echo -e " [${C_AZUL}$i${C_RESET}] - $caminho_relativo"
                    done
                    
                    echo -e "\n${C_AMARELO}Como deseja restaurar?${C_RESET}"
                    echo -e " -> Digite os NÚMEROS separados por espaço (Ex: 0 2 4)"
                    echo -e " -> Digite ${C_VERDE}TODOS${C_RESET} (ou T) para restaurar a lista atual inteira."
                    read -r -p "Escolha (ou V para cancelar): " escolhas_res
                    [[ "$escolhas_res" =~ ^[Vv]$ || -z "$escolhas_res" ]] && continue
                    
                    if [[ "$escolhas_res" == "TODOS" || "$escolhas_res" == "todos" || "$escolhas_res" == "T" || "$escolhas_res" == "t" ]]; then
                        escolhas_res=$(seq 0 $((${#arquivos_encontrados[@]} - 1)))
                    fi

                    local restaurados=0
                    for n_res in $escolhas_res; do
                        if [[ "$n_res" =~ ^[0-9]+$ ]] && [ "$n_res" -ge 0 ] && [ "$n_res" -lt "${#arquivos_encontrados[@]}" ]; then
                            local item_escolhido="${arquivos_encontrados[$n_res]}"
                            local caminho_relativo="${item_escolhido#$lixo/}"
                            local destino_final="$bd/$caminho_relativo"
                            
                            mkdir -p "$(dirname "$destino_final")" 2>/dev/null
                            if mv "$item_escolhido" "$destino_final" 2>/dev/null; then
                                echo -e " ${C_VERDE}[OK] Restaurado:${C_RESET} $(basename "$destino_final")"
                                restaurados=$((restaurados + 1))
                            else
                                echo -e " ${C_VERMELHO}[ERRO] Falha:${C_RESET} $(basename "$destino_final")"
                            fi
                        fi
                    done
                    
                    if [ "$restaurados" -gt 0 ]; then
                        msg_ok "$restaurados arquivo(s) retornado(s) à pasta original!"
                    else
                        msg_aviso "Nenhum arquivo válido foi restaurado."
                    fi
                    sleep 4
                fi
                ;;
            [Vv]) return ;;
            *) msg_erro "Opção inválida!"; sleep 1 ;;
        esac
    done
}

menu_permissoes() {
    while true; do
        header; echo -e "${C_AMARELO}--- 🛡️ GESTÃO DE PERMISSÕES E GESTORES ---${C_RESET}\n"
        selecionar_setor || return
        local sc="$SETOR_ESCOLHIDO"
        local sl=$(echo "$sc" | tr '[:upper:]' '[:lower:]')
        local bd="/mnt/dados/$sc"
        
        source "$bd/.gestores" 2>/dev/null
        local cg=${GESTOR:-"Nenhum"}
        local cs=${SUPER:-"Nenhum"}
        
        header; echo -e "${C_AMARELO}Setor selecionado: ${C_VERDE}$sc${C_RESET}\nGerente: ${C_AZUL}$cg${C_RESET} | Super: ${C_AZUL}$cs${C_RESET}\n"
        echo "  1) Adicionar Usuários ao Setor"
        echo "  2) Definir / Alterar GERENTE (Líder do Setor)"
        echo "  3) Definir / Alterar SUPER GERENTE (Acesso Global)"
        echo "  4) Conceder Acesso de Exceção (Acesso Cruzado)"
        echo "  5) Listar Exceções do Setor"
        echo "  6) Listar Membros do Setor"
        echo "  7) Desligar Usuário do Setor"
        echo "  8) Excluir / Arquivar Pastas"
        echo "  9) Criar Pasta ou Subpasta vinculada a Usuário"
        echo " 10) Transferir Posse de Pasta ou Subpasta"
        echo " 11) 🛡️ Blindar Setor (Sincronizar Espaço e Corrigir Permissões)"
        echo "  V) Voltar"
        linha_traco; read -r -p "Escolha: " opt_p

        case $opt_p in
            1)
                echo -e "\n${C_AZUL}--- ADICIONAR USUÁRIOS: $sc ---${C_RESET}"
                local membros=$(grep "^$sl:" /etc/group | cut -d: -f4)
                echo -e "Membros Atuais : ${C_AMARELO}${membros:-Nenhum}${C_RESET}\n"
                
                local flag_restart=0
                while true; do
                    read -r -p "Login do usuário (ou FIM para parar): " u
                    [[ -z "$u" || "$u" =~ ^(FIM|fim)$ ]] && break
                    local n_user=$(echo "$u" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
                    
                    if ! id "$n_user" &>/dev/null; then msg_erro "Usuário '$n_user' não existe!"; sleep 1; continue; fi

                    usermod -aG "$sl" "$n_user"
                    flag_restart=1
                    msg_ok "Usuário '$n_user' inserido no setor!"
                done
                if [ "$flag_restart" -eq 1 ]; then
                    msg_info "Reiniciando Samba para validar as permissões..."
                    systemctl restart smbd
                    sleep 1
                fi
                ;;
            2) 
                read -p "Login do NOVO Gerente: " n_raw
                local n=$(echo "$n_raw" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
                if ! id "$n" &>/dev/null; then msg_erro "Usuário não existe!"; sleep 2; continue; fi
                
                usermod -aG "$sl" "$n" 2>/dev/null
                sed -i '/^GESTOR=/d' "$bd/.gestores" 2>/dev/null
                echo "GESTOR=$n" >> "$bd/.gestores"
                
                msg_info "Aplicando permissões nas pastas..."
                for pasta in "$bd"/*; do
                    if [[ -d "$pasta" && "$(basename "$pasta")" != "PUBLICO" && "$(basename "$pasta")" != ".lixeira" ]]; then
                        if [[ "$cg" != "Nenhum" && "$cg" != "$n" ]]; then
                            setfacl -R -x u:"$cg" "$pasta" 2>/dev/null
                            setfacl -R -d -x u:"$cg" "$pasta" 2>/dev/null
                        fi
                        setfacl -R -m u:"$n":rwx "$pasta" 2>/dev/null
                        setfacl -R -d -m u:"$n":rwx "$pasta" 2>/dev/null
                    fi
                done
                systemctl restart smbd; msg_ok "Gerente atualizado com sucesso!"; sleep 2 
                ;;
            3) 
                read -p "Login do NOVO Super Gerente: " n_raw
                local n=$(echo "$n_raw" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
                if ! id "$n" &>/dev/null; then msg_erro "Usuário não existe!"; sleep 2; continue; fi
                
                usermod -aG "$sl" "$n" 2>/dev/null
                sed -i '/^SUPER=/d' "$bd/.gestores" 2>/dev/null
                echo "SUPER=$n" >> "$bd/.gestores"
                
                msg_info "Aplicando permissões recursivas globais..."
                for pasta in "$bd"/*; do
                    if [[ -d "$pasta" && "$(basename "$pasta")" != ".lixeira" ]]; then
                        if [[ "$cs" != "Nenhum" && "$cs" != "$n" ]]; then
                            setfacl -R -x u:"$cs" "$pasta" 2>/dev/null
                            setfacl -R -d -x u:"$cs" "$pasta" 2>/dev/null
                        fi
                        setfacl -R -m u:"$n":rwx "$pasta" 2>/dev/null
                        setfacl -R -d -m u:"$n":rwx "$pasta" 2>/dev/null
                    fi
                done
                [[ -d "$bd/PUBLICO" ]] && chown "$n":"$sl" "$bd/PUBLICO" 2>/dev/null
                systemctl restart smbd; msg_ok "Super Gerente atualizado!"; sleep 3 
                ;;
            4) 
                read -p "Login do usuário VISITANTE: " v_raw
                local v=$(echo "$v_raw" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
                if ! id "$v" &>/dev/null; then msg_erro "Usuário não existe!"; sleep 2; continue; fi
                
                read -p "Nome EXATO da pasta ALVO (Ex: PUBLICO): " a
                [[ -z "$a" ]] && continue
                if [[ "$a" == *".."* || "$a" == "." || "$a" == "/" || "$a" == ".lixeira" ]]; then msg_erro "Caminho bloqueado!"; sleep 2; continue; fi
                if [[ ! -d "$bd/$a" ]]; then msg_erro "A pasta '$a' não existe."; sleep 2; continue; fi

                usermod -aG "$sl" "$v" 2>/dev/null
                setfacl -R -m u:"$v":rwx "$bd/$a" 2>/dev/null
                setfacl -R -d -m u:"$v":rwx "$bd/$a" 2>/dev/null
                echo "VISITANTE: $v -> ALVO: $a | DATA: $(date +%d/%m/%Y)" >> "$bd/.excecoes"
                systemctl restart smbd; msg_ok "Acesso cruzado liberado!"; sleep 2 
                ;;
            5)
                echo -e "\n${C_AZUL}--- EXCEÇÕES DE ACESSO NO SETOR $sc ---${C_RESET}"
                if [[ -f "$bd/.excecoes" ]] && [ -s "$bd/.excecoes" ]; then cat "$bd/.excecoes"; else echo -e "${C_AMARELO}Nenhuma permissão registrada.${C_RESET}"; fi
                echo ""; read -p "Pressione Enter para voltar..." 
                ;;
            6)
                echo -e "\n${C_AZUL}--- MEMBROS DO SETOR $sc ---${C_RESET}"
                local membros=$(grep "^$sl:" /etc/group | cut -d: -f4)
                if [[ -z "$membros" ]]; then echo -e "${C_AMARELO}O setor está vazio no momento.${C_RESET}"; else echo "$membros" | tr ',' '\n' | awk '{print " - " $0}'; fi
                echo ""; read -p "Pressione Enter para voltar..." 
                ;;
            7)
                echo -e "\n${C_AZUL}--- DESLIGAR USUÁRIO DO SETOR ---${C_RESET}"
                read -p "Login do usuário a ser removido: " r_raw
                local r=$(echo "$r_raw" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
                if ! id "$r" &>/dev/null; then msg_erro "Usuário não existe!"; sleep 2; continue; fi
                
                msg_info "Removendo do grupo..."
                gpasswd -d "$r" "$sl" 2>/dev/null
                setfacl -R -x u:"$r" "$bd" 2>/dev/null
                setfacl -R -d -x u:"$r" "$bd" 2>/dev/null
                
                local pastas_dono=$(find "$bd" -mindepth 1 -maxdepth 1 -type d -user "$r" 2>/dev/null)
                if [[ -n "$pastas_dono" ]]; then
                    echo -e "\n${C_AMARELO}Pastas pessoais encontradas deste usuário:${C_RESET}"
                    echo "$pastas_dono" | awk -F'/' '{print " -> " $NF}'
                    echo " 1) MANTER INTACTA | 2) ARQUIVAR (_BKP) | 3) APAGAR TUDO"
                    read -p "Escolha: " o_rm
                    while IFS= read -r p; do
                        [[ -z "$p" ]] && continue
                        if [ "$o_rm" -eq 3 ]; then rm -rf "$p"; msg_ok "Apagada."; elif [ "$o_rm" -eq 2 ]; then mv "$p" "${p}_BKP_$(date +%F)"; chown -R root:"$sl" "${p}_BKP_$(date +%F)"; setfacl -b "${p}_BKP_$(date +%F)"; msg_ok "Arquivada."; fi
                    done <<< "$pastas_dono"
                fi
                systemctl restart smbd; msg_ok "Usuário desligado com sucesso!"; sleep 3 
                ;;
            8)
                echo -e "\n${C_AZUL}--- EXCLUIR / ARQUIVAR PASTA ---${C_RESET}"
                local avulsas=$(find "$bd" -mindepth 1 -maxdepth 1 -type d ! -name ".lixeira" 2>/dev/null)
                if [[ -n "$avulsas" ]]; then
                    echo -e "${C_AMARELO}Visão geral das pastas principais:${C_RESET}"
                    while IFS= read -r p; do
                        [[ -z "$p" ]] && continue
                        local d=$(stat -c '%U' "$p")
                        echo -e " - ${C_VERDE}$(basename "$p")${C_RESET} (Dono: $d)"
                    done <<< "$avulsas"
                fi
                echo ""
                read -p "Digite o NOME EXATO da pasta (ou V para voltar): " nome_alvo
                [[ "$nome_alvo" =~ ^[Vv]$ || -z "$nome_alvo" ]] && continue
                if [[ "$nome_alvo" == *".."* || "$nome_alvo" == "." || "$nome_alvo" == "/" || "$nome_alvo" == ".lixeira" ]]; then msg_erro "Caminho inválido!"; sleep 2; continue; fi
                if [[ "$nome_alvo" == "PUBLICO" || "$nome_alvo" == "PUBLICO/" ]]; then msg_erro "A raiz de PUBLICO não pode ser apagada."; sleep 3; continue; fi
                if [[ ! -d "$bd/$nome_alvo" ]]; then msg_erro "Pasta não existe!"; sleep 2; continue; fi
                
                echo -e "\nO que fazer com '${C_VERMELHO}$nome_alvo${C_RESET}'?"
                echo " 1) ARQUIVAR (Adiciona _BKP e trava) | 2) EXPLODIR (Apaga permanente) | 0) CANCELAR"
                read -p "Opção: " acao
                if [[ "$acao" == "1" ]]; then 
                    mv "$bd/$nome_alvo" "$bd/${nome_alvo}_BKP_$(date +%F_%H-%M)"
                    chown -R root:"$sl" "$bd/${nome_alvo}_BKP_$(date +%F_%H-%M)"
                    setfacl -b "$bd/${nome_alvo}_BKP_$(date +%F_%H-%M)" 2>/dev/null
                    msg_ok "Pasta arquivada!"
                elif [[ "$acao" == "2" ]]; then 
                    rm -rf "$bd/$nome_alvo"
                    msg_ok "Pasta destruída!"
                fi
                sleep 3
                ;;
            9)
                echo -e "\n${C_AZUL}--- CRIAR PASTA VINCULADA ---${C_RESET}"
                read -p "Nome da nova pasta: " n_pasta; [[ -z "$n_pasta" ]] && continue
                if [[ "$n_pasta" == *".."* || "$n_pasta" == "PUBLICO" || "$n_pasta" == "PUBLICO/" ]]; then msg_erro "Caminho protegido!"; sleep 2; continue; fi
                if [[ -d "$bd/$n_pasta" ]]; then msg_erro "O caminho já existe!"; sleep 2; continue; fi

                read -p "Login do dono: " d_raw
                local d_pasta=$(echo "$d_raw" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
                if ! id "$d_pasta" &>/dev/null; then msg_erro "Usuário não existe!"; sleep 2; continue; fi

                if ! groups "$d_pasta" | grep -q "\b$sl\b"; then usermod -aG "$sl" "$d_pasta"; fi

                mkdir -p "$bd/$n_pasta"; chown "$d_pasta":"$sl" "$bd/$n_pasta"; chmod 700 "$bd/$n_pasta"
                setfacl -R -m g::--- "$bd/$n_pasta" 2>/dev/null; setfacl -R -m other::--- "$bd/$n_pasta" 2>/dev/null
                setfacl -R -m u:"$d_pasta":rwx "$bd/$n_pasta" 2>/dev/null; setfacl -R -d -m u:"$d_pasta":rwx "$bd/$n_pasta" 2>/dev/null
                
                [[ "$cg" != "Nenhum" && "$d_pasta" != "$cg" ]] && setfacl -R -m u:"$cg":rwx "$bd/$n_pasta" && setfacl -R -d -m u:"$cg":rwx "$bd/$n_pasta"
                [[ "$cs" != "Nenhum" && "$d_pasta" != "$cs" ]] && setfacl -R -m u:"$cs":rwx "$bd/$n_pasta" && setfacl -R -d -m u:"$cs":rwx "$bd/$n_pasta"
                msg_ok "Pasta '$n_pasta' criada para '$d_pasta'!"; sleep 3
                ;;
            10)
                echo -e "\n${C_AZUL}--- TRANSFERIR POSSE ---${C_RESET}"
                read -p "Nome exato da pasta: " p_alvo; [[ -z "$p_alvo" ]] && continue
                if [[ "$p_alvo" == *".."* || "$p_alvo" == "." || "$p_alvo" == "/" || "$p_alvo" == ".lixeira" || "$p_alvo" == "PUBLICO" ]]; then msg_erro "Caminho protegido!"; sleep 2; continue; fi
                if [[ ! -d "$bd/$p_alvo" ]]; then msg_erro "Pasta não existe!"; sleep 2; continue; fi

                read -p "Login do NOVO DONO: " n_dono_raw
                local n_dono=$(echo "$n_dono_raw" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
                if ! id "$n_dono" &>/dev/null; then msg_erro "Usuário não existe!"; sleep 2; continue; fi

                if ! groups "$n_dono" | grep -q "\b$sl\b"; then usermod -aG "$sl" "$n_dono"; fi

                msg_info "Transferindo a posse..."
                chown -R "$n_dono":"$sl" "$bd/$p_alvo"
                setfacl -R -m u:"$n_dono":rwx "$bd/$p_alvo" 2>/dev/null
                setfacl -R -d -m u:"$n_dono":rwx "$bd/$p_alvo" 2>/dev/null
                
                [[ "$cg" != "Nenhum" && "$n_dono" != "$cg" ]] && setfacl -R -m u:"$cg":rwx "$bd/$p_alvo" && setfacl -R -d -m u:"$cg":rwx "$bd/$p_alvo"
                [[ "$cs" != "Nenhum" && "$n_dono" != "$cs" ]] && setfacl -R -m u:"$cs":rwx "$bd/$p_alvo" && setfacl -R -d -m u:"$cs":rwx "$bd/$p_alvo"
                systemctl restart smbd; msg_ok "Posse de '$p_alvo' transferida para '$n_dono'!"; sleep 3
                ;;
            11)
                echo -e "\n${C_AZUL}--- 🛡️ BLINDAGEM DE SETOR E NORMALIZAÇÃO ---${C_RESET}"
                echo -e "Esta ferramenta varre a pasta, corrige permissões bagunçadas e"
                echo -e "sincroniza o dono dos arquivos para corrigir divergências de espaço."
                echo ""
                read -r -p "Deseja iniciar a normalização no setor $sc? (SIM/NAO): " conf_blind
                if [[ "$conf_blind" != "SIM" ]]; then msg_aviso "Operação cancelada."; sleep 2; continue; fi
                
                if grep -A 10 "\[$sc\]" /etc/samba/smb.conf | grep -q "guest ok = yes"; then
                    msg_info "Setor Público de Acesso Livre detectado. Aplicando vacina de permissões..."
                    chown -R nobody:"$sl" "$bd" 2>/dev/null
                    setfacl -R -b "$bd" 2>/dev/null
                    find "$bd" -type d -exec chmod 2777 {} \; 2>/dev/null
                    find "$bd" -type f -exec chmod 666 {} \; 2>/dev/null
                    chmod 2777 "$bd/.lixeira" 2>/dev/null
                    systemctl restart smbd; msg_ok "Permissões públicas reestabelecidas (Destravado)!"
                    sleep 4
                    continue
                fi

                echo -e "\n${C_AMARELO}Qual é a arquitetura original deste setor privado?${C_RESET}"
                echo " 1) ESTRUTURA BLINDADA (Isolar subpastas de usuários e focar na subpasta PUBLICO)"
                echo " 2) PASTA SOLTA / COLABORAÇÃO (Todos do grupo acessam tudo irrestritamente)"
                read -r -p "Escolha (1 ou 2): " opt_arq_blind
                
                msg_info "Iniciando varredura de segurança em $bd... (Pode demorar dependendo do tamanho)"
                
                chgrp -R "$sl" "$bd" 2>/dev/null
                chown root:"$sl" "$bd" 2>/dev/null
                
                if [[ "$opt_arq_blind" == "2" ]]; then
                    setfacl -R -b "$bd" 2>/dev/null
                    chmod -R 2770 "$bd" 2>/dev/null
                    chmod 1777 "$bd/.lixeira" 2>/dev/null
                    setfacl -R -d -m g:"$sl":rwx "$bd" 2>/dev/null
                else
                    for p in "$bd"/*; do
                        local nome_p=$(basename "$p")
                        [[ "$nome_p" == ".lixeira" ]] && continue
                        
                        if [[ "$nome_p" == "PUBLICO" ]]; then
                            echo -e "\n${C_AMARELO}Como deseja o comportamento da subpasta PUBLICO?${C_RESET}"
                            echo " 1) PADRÃO (Dono Apaga): Apenas quem criou pode apagar o arquivo."
                            echo " 2) COLABORAÇÃO (Todos Apagam): Qualquer membro apaga qualquer arquivo."
                            read -r -p "Escolha (Enter para Padrão 1): " opt_blind_pub

                            chmod -t "$p" 2>/dev/null
                            if [[ "$opt_blind_pub" == "2" ]]; then
                                chmod 2770 "$p" 2>/dev/null
                                setfacl -R -m g:"$sl":rwx "$p" 2>/dev/null
                                setfacl -R -d -m g:"$sl":rwx "$p" 2>/dev/null
                                echo -e " - ${C_VERDE}Pasta Pública configurada para Colaboração Total.${C_RESET}"
                            else
                                chmod 1770 "$p" 2>/dev/null
                                setfacl -R -x g:"$sl" "$p" 2>/dev/null
                                setfacl -R -d -x g:"$sl" "$p" 2>/dev/null
                                echo -e " - ${C_VERDE}Pasta Pública configurada para Proteção de Dono.${C_RESET}"
                            fi
                            continue
                        fi
                        
                        if [[ -d "$p" ]]; then
                            setfacl -R -m g::--- "$p" 2>/dev/null
                            setfacl -R -d -m g::--- "$p" 2>/dev/null
                            setfacl -R -m other::--- "$p" 2>/dev/null
                            setfacl -R -d -m other::--- "$p" 2>/dev/null
                            echo -e " - ${C_VERDE}Pasta isolada e blindada:${C_RESET} $nome_p"
                        fi
                    done
                fi
                systemctl restart smbd; msg_ok "Blindagem concluída! As quotas agora devem estar corretas."
                sleep 4
                ;;
            [Vv]) continue ;;
            *) msg_erro "Inválido"; sleep 1 ;;
        esac
    done
}

# ==============================================================================
# MÓDULOS NUVEM, REDE, STORAGE E RESET
# ==============================================================================
menu_nuvem() {
    while true; do
        header; echo -e "${C_AMARELO}--- ☁️ GESTÃO DE BACKUP EM NUVEM (GOOGLE DRIVE) ---${C_RESET}\n"
        echo " 1) ⚡ Vínculo Rápido (Configurar Drive via Token)"
        echo " 2) 🔐 Habilitar Cofre Criptografado"
        echo " 3) 🕒 Agendar / Editar Backup Automático Diário"
        echo " 4) 👁️ Status / Ver Agendamento Atual"
        echo " 5) 🚀 Forçar Sincronização Agora (Manual)"
        echo " 6) 🛑 Remover Rotina de Backup"
        echo " 7) 📡 Acompanhar Logs em Tempo Real (Live Monitor)"
        echo " V) Voltar ao Menu Principal"
        linha_traco; read -r -p "Escolha: " opt_c

        case $opt_c in
            1) 
                echo -e "\n${C_CIANO}PASSO ÚNICO:${C_RESET} No seu navegador, logue no Google e autorize o Rclone."
                read -p "Cole o Token: " token
                rclone config create gdrive drive scope=drive token="$token" --non-interactive
                sleep 2 
                ;;
            2) 
                if ! rclone listremotes | grep -q "gdrive:"; then msg_erro "Configure a Opção 1 primeiro."; sleep 2; continue; fi
                read -p "Pasta raiz no Drive (Ex: BACKUP): " pc
                read -rs -p "Senha do Cofre (Guarde-a bem!): " pass; echo
                rclone config create gdrive_crypt crypt remote="gdrive:${pc#gdrive:}" password="$pass" --non-interactive
                msg_ok "Cofre criado com sucesso!"; sleep 2 
                ;;
            3|5) 
                if ! rclone listremotes | grep -q "gdrive:"; then msg_erro "Google Drive não configurado!"; sleep 2; continue; fi
                echo -e "\n${C_AZUL}--- CONFIGURAÇÃO DE ENVIO ---${C_RESET}"
                read -e -p "Origem [Enter para /mnt/dados]: " src; src=${src:-/mnt/dados}
                echo " 1) Drive NORMAL (Visível) | 2) COFRE CRIPTOGRAFADO (Ilegível)"; read -p "Opção: " d_opt
                
                if [[ "$d_opt" == "2" ]]; then 
                    if ! rclone listremotes | grep -q "gdrive_crypt:"; then msg_erro "Cofre não encontrado."; sleep 2; continue; fi
                    dst="gdrive_crypt:"
                else 
                    read -p "Nome da Pasta de Destino no Drive: " p_drv; dst="gdrive:${p_drv#gdrive:}"
                fi
                
                echo -e "\n 1) CÓPIA SEGURA (Não apaga lixo) | 2) ESPELHO/SYNC (Apaga lixo da nuvem)"; read -p "Modo: " m_opt
                cmd="rclone copy"; extra=""
                [[ "$m_opt" == "2" ]] && cmd="rclone sync" && extra="--delete-excluded"

                filtros="--exclude .lixeira/** --exclude aquota.* --exclude .gestores --exclude .excecoes --tpslimit 8 --transfers 4 --checkers 8 --drive-pacer-min-sleep 100ms"

                if [[ "$opt_c" == "3" ]]; then
                    read -p "Hora para rodar (HH:MM): " h_bkp
                    [[ ! "$h_bkp" =~ ^[0-2][0-9]:[0-5][0-9]$ ]] && msg_erro "Hora inválida!" && sleep 2 && continue
                    h=$(echo "$h_bkp" | cut -d: -f1); m=$(echo "$h_bkp" | cut -d: -f2)
                    
                    echo -e "\n${C_AMARELO}Frequência do Backup:${C_RESET}"
                    echo " 1) Todos os dias"
                    echo " 2) Apenas Dias Úteis (Segunda a Sexta)"
                    read -p "Opção (1 ou 2): " freq_opt
                    local cron_dow="*"
                    [[ "$freq_opt" == "2" ]] && cron_dow="1-5"
                    
                    cat <<EOF > /opt/samba_backup.sh
#!/bin/bash
# Backup Automático Samba -> Google Drive (V24.1)
echo "Iniciando backup: \$(date)" >> /var/log/samba_backup.log
$cmd "$src" "$dst" $filtros $extra -v --log-file=/var/log/samba_backup.log
echo "Backup finalizado: \$(date)" >> /var/log/samba_backup.log
EOF
                    chmod +x /opt/samba_backup.sh
                    crontab -l 2>/dev/null | grep -v "/opt/samba_backup.sh" | { cat; echo "$m $h * * $cron_dow /bin/bash /opt/samba_backup.sh"; } | crontab -
                    msg_ok "Rotina programada com sucesso!"; sleep 3
                else
                    echo -e "\n${C_VERMELHO}Iniciando comunicação com a nuvem... Não feche esta tela!${C_RESET}"
                    linha_traco
                    $cmd "$src" "$dst" $filtros $extra --stats=5s -P
                    linha_traco
                    msg_ok "Procedimento manual finalizado!"; sleep 3
                fi 
                ;;
            4)
                echo -e "\n${C_AZUL}--- STATUS DO AGENDAMENTO ---${C_RESET}"
                if crontab -l 2>/dev/null | grep -q "/opt/samba_backup.sh"; then
                    local cron_job=$(crontab -l 2>/dev/null | grep "/opt/samba_backup.sh")
                    local m_cron=$(echo "$cron_job" | awk '{print $1}')
                    local h_cron=$(echo "$cron_job" | awk '{print $2}')
                    local dow_cron=$(echo "$cron_job" | awk '{print $5}')
                    
                    local dias="Todos os dias"
                    [[ "$dow_cron" == "1-5" ]] && dias="Segunda a Sexta-feira"
                    
                    echo -e " ${C_VERDE}Status:${C_RESET} ATIVO"
                    echo -e " ${C_AMARELO}Horário:${C_RESET} $(printf "%02d:%02d" $h_cron $m_cron) ($dias)"
                    
                    if [[ -f "/var/log/samba_backup.log" ]]; then
                        echo -e "\n ${C_CIANO}Últimos Registros (Top 5):${C_RESET}"
                        tail -n 5 /var/log/samba_backup.log | while read -r line; do echo "  > $line"; done
                    fi
                else
                    echo -e " ${C_AMARELO}Status:${C_RESET} NENHUM BACKUP AGENDADO NO MOMENTO."
                fi
                echo ""; read -p "Pressione Enter para voltar..."
                ;;
            6) 
                read -r -p "Cancelar backup automático? (SIM/NAO): " conf_rm
                if [[ "$conf_rm" == "SIM" ]]; then
                    crontab -l 2>/dev/null | grep -v "/opt/samba_backup.sh" | crontab -
                    rm -f /opt/samba_backup.sh
                    msg_ok "Rotina Removida do sistema!"; 
                else msg_aviso "Cancelado."; fi
                sleep 2 
                ;;
            7)
                if [[ ! -f "/var/log/samba_backup.log" ]]; then
                    echo -e "\n${C_AZUL}--- LOGS DE BACKUP EM TEMPO REAL ---${C_RESET}"
                    msg_aviso "O arquivo de log ainda não existe. Nenhum backup foi rodado."
                    sleep 3
                else
                    header
                    echo -e "${C_AMARELO}--- ☁️ GESTÃO DE BACKUP EM NUVEM (GOOGLE DRIVE) ---${C_RESET}\n"
                    echo " 1) ⚡ Vínculo Rápido (Configurar Drive via Token)"
                    echo " 2) 🔐 Habilitar Cofre Criptografado"
                    echo " 3) 🕒 Agendar / Editar Backup Automático Diário"
                    echo " 4) 👁️ Status / Ver Agendamento Atual"
                    echo " 5) 🚀 Forçar Sincronização Agora (Manual)"
                    echo " 6) 🛑 Remover Rotina de Backup"
                    echo " 7) 📡 Acompanhar Logs em Tempo Real (Live Monitor)"
                    echo " V) Voltar ao Menu Principal"
                    linha_traco
                    echo -e "${C_AZUL}--- 📡 LOGS DE BACKUP (Atualização passiva - 0% CPU) ---${C_RESET}"
                    echo -e "${C_AMARELO}Pressione [CTRL + C] para parar de assistir e voltar ao menu.${C_RESET}\n"

                    local h=$(get_term_height)
                    local start_row=22

                    if [[ $h -gt 25 ]]; then
                        printf "\e[%d;%dr" $start_row $h
                        printf "\e[%d;1H" $start_row
                        tput civis
                        trap 'printf "\e[r"; tput cnorm; trap - SIGINT' SIGINT
                        tail -n $((h - start_row)) -f /var/log/samba_backup.log
                        printf "\e[r"
                        tput cnorm
                        trap - SIGINT
                    else
                        trap 'trap - SIGINT' SIGINT
                        tail -f /var/log/samba_backup.log
                        trap - SIGINT
                    fi
                fi
                ;;
            [Vv]) return ;;
            *) msg_erro "Inválido!"; sleep 1 ;;
        esac
    done
}

configurar_rede() {
    header
    echo -e "${C_AMARELO}--- 🌐 CONFIGURAÇÃO DE REDE (IP FIXO) ---${C_RESET}\n"

    local interface=$(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -v -e "lo" -e "docker" -e "virbr" | head -n 1 | xargs)
    if [[ -z "$interface" ]]; then msg_erro "Não foi possível detectar a placa de rede."; sleep 2; return; fi

    echo -e "Placa de Rede Detectada e Limpa: ${C_VERDE}$interface${C_RESET}\n"

    read -r -p "Novo IP (OBRIGATÓRIO colocar o /24. Ex: 10.1.10.54/24) ou V para voltar: " novo_ip
    [[ "$novo_ip" =~ ^[Vv]$ ]] && return
    if [[ ! "$novo_ip" == *"/"* ]]; then msg_erro "Faltou a máscara (Ex: /24)."; sleep 3; return; fi

    read -r -p "Gateway da Rede (Ex: 10.1.10.1): " novo_gw
    read -r -p "DNS Principal (Ex: 8.8.8.8): " novo_dns1
    read -r -p "DNS Secundário (Ex: 1.1.1.1) (Opcional): " novo_dns2

    echo -e "\n${C_VERMELHO}>>> AVISO IMPORTANTE <<<${C_RESET}"
    echo -e "Sua conexão SSH vai CONGELAR e CAIR assim que o IP for trocado."
    linha_traco; read -r -p "Aplicar configuração? (SIM/NAO): " confirma

    if [[ "$confirma" == "SIM" ]]; then
        mkdir -p /etc/netplan/backup_rede
        mv /etc/netplan/*.yaml /etc/netplan/backup_rede/ 2>/dev/null
        local dns_list="[$novo_dns1"
        [[ -n "$novo_dns2" ]] && dns_list="$dns_list, $novo_dns2"
        dns_list="$dns_list]"

        cat <<EOF > /etc/netplan/01-rede-fixa.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    $interface:
      dhcp4: no
      addresses:
        - $novo_ip
      routes:
        - to: default
          via: $novo_gw
      nameservers:
        addresses: $dns_list
EOF
        
        chmod 600 /etc/netplan/01-rede-fixa.yaml 2>/dev/null
        local tipo_virt=$(systemd-detect-virt 2>/dev/null || echo "none")
        
        systemctl unmask systemd-networkd >/dev/null 2>&1
        systemctl enable systemd-networkd >/dev/null 2>&1
        
        if [[ "$tipo_virt" == "lxc" || "$tipo_virt" == "wsl" || "$tipo_virt" == "container" ]]; then
            msg_info "Ambiente LXC. Injetando IP na interface $interface e salvando Netplan..."
            (
                sleep 2
                ip addr flush dev "$interface" 2>/dev/null
                ip addr add "$novo_ip" dev "$interface" 2>/dev/null
                ip link set dev "$interface" up 2>/dev/null
                ip route add default via "$novo_gw" 2>/dev/null
                netplan generate 2>/dev/null
                systemctl restart systemd-networkd 2>/dev/null
            ) & disown
        else
            msg_info "Ambiente Físico/VM. Aplicando via Netplan..."
            ( sleep 2; netplan apply >/dev/null 2>&1 ) & disown
        fi
        
        echo -e "\n${C_VERDE}[ OK ] O MÍSSIL FOI LANÇADO!${C_RESET}"
        echo -e "${C_AMARELO}Aguarde a tela congelar, feche este terminal e conecte no novo IP: $novo_ip${C_RESET}"
        sleep 1
        exit 0
    else
        msg_aviso "Operação cancelada."; sleep 2
    fi
}

preparar_disco() {
    while true; do
        header
        echo -e "${C_AMARELO}--- ⚙️ CONFIGURAÇÃO DE STORAGE ---${C_RESET}\n"
        echo " 1) 💽 Adicionar e Formatar NOVO DISCO (Recomendado p/ Servidores Grandes)"
        echo " 2) 💻 Usar o Disco Principal do Sistema (Instalações Single-Node / VPS)"
        echo " V) Voltar ao Menu Principal"
        linha_traco; read -r -p "Escolha: " opt_st

        case $opt_st in
            1)
                msg_info "Discos detectados no sistema:"
                lsblk -dp | grep -v "loop" | awk '{print "  " $1 " - " $4}'
                echo ""
                read -r -p "Digite o caminho do NOVO disco (Ex: /dev/sdb) ou V para voltar: " disco
                [[ "$disco" =~ ^[Vv]$ ]] && continue
                if [[ ! -b "$disco" ]]; then msg_erro "Disco '$disco' não encontrado."; sleep 2; continue; fi
                
                echo -e "\n${C_VERMELHO}PERIGO: TODOS OS DADOS EM $disco SERÃO DESTRUÍDOS!${C_RESET}\n"
                read -r -p "Tem certeza absoluta que deseja formatar $disco? (digite SIM para continuar): " confirma
                if [[ "$confirma" != "SIM" ]]; then continue; fi

                msg_info "Formatando disco..."
                parted -s "$disco" mklabel gpt
                parted -s "$disco" mkpart primary ext4 0% 100%
                local particao="${disco}1"
                if [[ "$disco" == *"nvme"* ]]; then particao="${disco}p1"; fi
                sleep 2 
                mkfs.ext4 -F "$particao" >/dev/null
                tune2fs -m 0 "$particao" >/dev/null

                mkdir -p /mnt/dados
                local uuid=$(blkid -s UUID -o value "$particao")
                cp /etc/fstab /etc/fstab.bak_$(date +%F_%T)
                sed -i '\|/mnt/dados|d' /etc/fstab
                echo "UUID=$uuid /mnt/dados ext4 defaults,acl,usrquota,grpquota 0 2" >> /etc/fstab

                mount -a
                quotacheck -cumg /mnt/dados 2>/dev/null
                quotaon -v /mnt/dados 2>/dev/null
                msg_ok "Disco montado e configurado com sucesso!"
                df -h /mnt/dados
                echo ""; read -r -p "Pressione Enter para continuar..."
                ;;
            2)
                echo -e "\n${C_AZUL}Configurando o ambiente para usar apenas o disco C: do Linux...${C_RESET}"
                mkdir -p /mnt/dados
                chmod 755 /mnt/dados
                
                msg_info "Forçando injeção de cotas na partição raiz..."
                garantir_motor_quotas
                
                msg_ok "O servidor está pronto para salvar os dados no disco principal e rastrear o espaço!"
                df -h /mnt/dados
                echo ""; read -r -p "Pressione Enter para voltar..."
                ;;
            [Vv]) return ;;
            *) msg_erro "Opção inválida!"; sleep 1 ;;
        esac
    done
}

reset_total_servidor() {
    header
    local w=$(get_term_width)
    printf "${C_VERMELHO}%*s${C_RESET}\n" "$w" "" | tr ' ' '='
    center_text "☢️ PERIGO EXTREMO: RESET TOTAL DO SERVIDOR DE ARQUIVOS" "$C_VERMELHO"
    printf "${C_VERMELHO}%*s${C_RESET}\n" "$w" "" | tr ' ' '='
    
    echo -e "\nEsta opção é destrutiva. Ela irá:"
    echo -e " 1. Apagar TODOS os setores, grupos e usuários do Samba."
    echo -e " 2. Deletar TODAS as pastas, arquivos e lixeiras de /mnt/dados."
    echo -e " 3. Limpar todas as regras do arquivo smb.conf."
    echo -e "\n${C_AMARELO}Para confirmar o apagão, digite exatamente: ${C_VERMELHO}DESTRUIR TUDO${C_RESET}"
    read -r confirma

    if [[ "$confirma" != "DESTRUIR TUDO" ]]; then return; fi

    echo ""
    msg_info "Parando serviço Samba..."
    systemctl stop smbd

    local setores=($(listar_setores_samba))
    for s in "${setores[@]}"; do
        groupdel "$(echo "$s" | tr '[:upper:]' '[:lower:]')" &>/dev/null
    done

    msg_info "Removendo usuários do Samba..."
    for u in $(awk -F: '$3 >= 1000 && $7 == "/usr/sbin/nologin" {print $1}' /etc/passwd); do
        smbpasswd -x "$u" &>/dev/null
        userdel -f "$u" &>/dev/null
    done

    msg_info "Limpando arquivo smb.conf..."
    cp /etc/samba/smb.conf /etc/samba/smb.conf.bak_pre_reset_$(date +%F_%T)
    awk '
        /^\[.*\]$/ {
            if ($0 ~ /^\[global\]$/ || $0 ~ /^\[printers\]$/ || $0 ~ /^\[print\$\]$/) { skip = 0 } else { skip = 1 }
        }
        !skip { print $0 }
    ' /etc/samba/smb.conf.bak_pre_reset_* | tail -n +1 > /tmp/smb.conf.clean
    cat /tmp/smb.conf.clean > /etc/samba/smb.conf

    msg_info "Formatando logicamente a partição /mnt/dados..."
    rm -rf /mnt/dados/*

    msg_info "Zerando banco de Quotas..."
    local pm=$(df -P /mnt/dados 2>/dev/null | tail -n 1 | awk '{print $6}')
    [[ -z "$pm" ]] && pm="/"
    quotacheck -cumg "$pm" 2>/dev/null

    msg_info "Reiniciando serviços..."
    systemctl start smbd

    echo ""
    msg_ok "Reset Total concluído! O servidor está limpo e zerado como de fábrica."
    echo ""; read -r -p "Pressione Enter para voltar ao menu..."
}

# --- INICIALIZAÇÃO ---
verificar_dependencias

if [ ! -d "/mnt/dados" ]; then 
    mkdir -p /mnt/dados
    chmod 755 /mnt/dados
fi

# ATIVAÇÕES SILENCIOSAS DE AMBIENTE
garantir_samba_guest >/dev/null 2>&1
garantir_motor_quotas >/dev/null 2>&1

# ==============================================================================
# MENU PRINCIPAL
# ==============================================================================
while true; do
    header
    echo -e "  [ ${C_VERDE}1${C_RESET} ] 👤 Usuários    (Criar / Listar / Senhas / Excluir)"
    echo -e "  [ ${C_VERDE}2${C_RESET} ] 📁 Setores     (Criar / Listar / Dashboard / Lixeira / Filtros)"
    echo -e "  [ ${C_AMARELO}3${C_RESET} ] 🛡️ Permissões  (Acesso / Gestores / Subpastas / Blindagem)"
    echo -e "  [ ${C_CIANO}4${C_RESET} ] 🌐 Rede        (Configurar IP Fixo do Servidor)"
    echo -e "  [ ${C_AZUL}5${C_RESET} ] ☁️ Backup      (Sincronizar e Criptografar Nuvem)"
    echo -e "  [ ${C_CIANO}6${C_RESET} ] ⚙️ Storage     (Preparar/Formatar Discos e Quotas)"
    echo -e "  [ ${C_VERMELHO}99${C_RESET}] ☢️ RESET TOTAL (Apagar Servidor Inteiro)"
    echo -e "  [ ${C_AMARELO}0${C_RESET} ] ❌ Sair"
    linha
    read -r -p "Escolha o módulo: " opcao

    case $opcao in
        1) menu_usuarios ;;
        2) menu_setores ;;
        3) menu_permissoes ;;
        4) configurar_rede ;;
        5) menu_nuvem ;;
        6) preparar_disco ;;
        99) reset_total_servidor ;;
        0) clear; msg_ok "Sistema encerrado!"; exit 0 ;;
        *) msg_erro "Opção inválida!"; sleep 1 ;;
    esac
done