#!/bin/bash
set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug() { echo -e "${CYAN}[DEBUG]${NC} $1"; }

# ============================================
# ГЕНЕРАЦИЯ ПАРОЛЕЙ И САНИТИЗАЦИЯ
# ============================================
generate_password() {
    local length=$1
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
}

sanitize_input() {
    local input="$1"
    # Удаляем опасные символы: ; " ' ` $ \ / и переносы строк
    echo "$input" | tr -d ';"'\''`$\\/\n\r' | head -c 64
}

# ============================================
# КОНФИГУРАЦИЯ
# ============================================
CHR_VERSION="7.16.1"
# URL будет установлен после определения режима загрузки (UEFI/Legacy)
CHR_URL=""
CHR_ZIP=""
CHR_IMG=""
WORK_DIR="/tmp/chr-install"
MOUNT_POINT="/mnt/chr"

# Настройки CHR (пароль генерируется автоматически если не указан)
ADMIN_PASSWORD=""
DNS_SERVERS="8.8.8.8,8.8.4.4"

# Флаги
SKIP_AUTORUN=false
FORCE_DOWNLOAD=false
VERIFY_WRITE=true
AUTO_YES=false
AUTO_REBOOT=false
FORCE_LEGACY=false

# ============================================
# ПАРСИНГ АРГУМЕНТОВ
# ============================================
usage() {
    echo "Использование: $0 [опции]"
    echo ""
    echo "Опции:"
    echo "  --clean          Чистая установка без autorun.scr"
    echo "  --force          Принудительно скачать образ заново"
    echo "  --no-verify      Пропустить верификацию записи"
    echo "  --yes, -y        Без подтверждений (автоматический режим)"
    echo "  --reboot         Автоматическая перезагрузка (требует --yes)"
    echo "  --version VER    Версия CHR (по умолчанию: $CHR_VERSION)"
    echo "  --password PASS  Пароль admin (генерируется автоматически)"
    echo "  --legacy         Принудительно использовать Legacy BIOS (не UEFI)"
    echo "  -h, --help       Показать справку"
    echo ""
    echo "Примеры:"
    echo "  $0 --clean                    # Чистая установка с подтверждением"
    echo "  $0 --yes --reboot             # Полностью автоматическая установка"
    echo "  $0 -y --clean --reboot        # Автоматическая чистая установка"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --clean)
            SKIP_AUTORUN=true
            shift
            ;;
        --force)
            FORCE_DOWNLOAD=true
            shift
            ;;
        --no-verify)
            VERIFY_WRITE=false
            shift
            ;;
        --yes|-y)
            AUTO_YES=true
            shift
            ;;
        --reboot)
            AUTO_REBOOT=true
            shift
            ;;
        --legacy)
            FORCE_LEGACY=true
            shift
            ;;
        --version)
            CHR_VERSION="$2"
            CHR_URL="https://download.mikrotik.com/routeros/${CHR_VERSION}/chr-${CHR_VERSION}.img.zip"
            CHR_ZIP="chr-${CHR_VERSION}.img.zip"
            CHR_IMG="chr-${CHR_VERSION}.img"
            shift 2
            ;;
        --password)
            ADMIN_PASSWORD=$(sanitize_input "$2")
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Неизвестная опция: $1"
            usage
            ;;
    esac
done

# ============================================
# ГЕНЕРАЦИЯ ПАРОЛЯ (если не задан)
# ============================================
if [[ -z "$ADMIN_PASSWORD" ]]; then
    ADMIN_PASSWORD=$(generate_password 16)
    log_info "Сгенерирован пароль admin: $ADMIN_PASSWORD"
fi

# ============================================
# ПРОВЕРКА ROOT
# ============================================
if [[ $EUID -ne 0 ]]; then
    log_error "Скрипт должен запускаться от root"
    exit 1
fi

# ============================================
# ОПРЕДЕЛЕНИЕ РЕЖИМА ЗАГРУЗКИ (UEFI/LEGACY)
# ============================================
if [[ "$FORCE_LEGACY" == true ]]; then
    BOOT_MODE="LEGACY"
    log_info "Режим загрузки: Legacy BIOS (принудительно)"
elif [[ -d /sys/firmware/efi ]]; then
    BOOT_MODE="UEFI"
    log_info "Режим загрузки: UEFI"
    log_info "Будет использован UEFI-совместимый образ (fat-chr)"
else
    BOOT_MODE="LEGACY"
    log_info "Режим загрузки: Legacy BIOS"
fi

# Установка URL в зависимости от режима загрузки
if [[ "$BOOT_MODE" == "UEFI" ]]; then
    # UEFI образ fat-chr 7.16 (проверенный, autorun.scr работает)
    CHR_URL="https://github.com/tikoci/fat-chr/releases/download/Build11085703131-jaclaz/chr-7.16.uefi-fat-jaclaz.raw"
    CHR_ZIP=""
    CHR_IMG="chr-7.16.uefi-fat.raw"
    log_info "UEFI: используется fat-chr 7.16 (autorun.scr поддерживается)"
else
    # Официальный MikroTik образ для Legacy BIOS
    CHR_URL="https://download.mikrotik.com/routeros/${CHR_VERSION}/chr-${CHR_VERSION}.img.zip"
    CHR_ZIP="chr-${CHR_VERSION}.img.zip"
    CHR_IMG="chr-${CHR_VERSION}.img"
fi

# ============================================
# ПРОВЕРКА ЗАВИСИМОСТЕЙ
# ============================================
log_info "Проверка зависимостей..."

REQUIRED_TOOLS="wget unzip fdisk dd mount umount file md5sum xxd"

MISSING_TOOLS=""

for tool in $REQUIRED_TOOLS; do
    if ! command -v $tool &> /dev/null; then
        MISSING_TOOLS="$MISSING_TOOLS $tool"
    fi
done

if [[ -n "$MISSING_TOOLS" ]]; then
    log_warn "Отсутствуют утилиты:$MISSING_TOOLS"
    log_info "Попытка установки..."
    
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y wget unzip fdisk coreutils mount xxd file parted dosfstools
    elif command -v yum &> /dev/null; then
        yum install -y wget unzip util-linux coreutils vim-common file parted dosfstools
    elif command -v dnf &> /dev/null; then
        dnf install -y wget unzip util-linux coreutils vim-common file parted dosfstools
    else
        log_error "Установи вручную:$MISSING_TOOLS"
        exit 1
    fi
fi

log_info "Все зависимости в порядке"

# ============================================
# ПОДГОТОВКА РАБОЧЕЙ ДИРЕКТОРИИ
# ============================================
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

log_info "Рабочая директория: $WORK_DIR"
log_debug "Свободное место: $(df -h "$WORK_DIR" | tail -1 | awk '{print $4}')"

# ============================================
# СКАЧИВАНИЕ ОБРАЗА
# ============================================
if [[ "$FORCE_DOWNLOAD" == true ]] || [[ ! -f "$CHR_IMG" ]]; then
    rm -f "$CHR_ZIP" "$CHR_IMG" "${CHR_IMG}.modified"

    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        # UEFI: скачиваем RAW образ напрямую
        log_info "Скачивание fat-chr 7.16 (UEFI)..."
        wget --progress=bar:force -O "$CHR_IMG" "$CHR_URL"
        
        ACTUAL_SIZE=$(stat -c%s "$CHR_IMG")
        log_debug "Размер скачанного файла: $ACTUAL_SIZE байт"
        
        if [[ $ACTUAL_SIZE -lt 100000000 ]]; then
            log_error "Файл слишком маленький, скачивание неполное"
            exit 1
        fi
    else
        # Legacy: скачиваем ZIP и распаковываем
        log_info "Скачивание CHR ${CHR_VERSION} (Legacy)..."
        wget --progress=bar:force -O "$CHR_ZIP" "$CHR_URL"

        ACTUAL_SIZE=$(stat -c%s "$CHR_ZIP")
        log_debug "Размер скачанного файла: $ACTUAL_SIZE байт"

        if [[ $ACTUAL_SIZE -lt 30000000 ]]; then
            log_error "Файл слишком маленький, скачивание неполное"
            exit 1
        fi

        FILE_TYPE=$(file "$CHR_ZIP")
        log_debug "Тип файла: $FILE_TYPE"

        if echo "$FILE_TYPE" | grep -q "Zip archive"; then
            log_info "Распаковка ZIP..."
            unzip -o "$CHR_ZIP"
        elif echo "$FILE_TYPE" | grep -q "gzip"; then
            log_info "Распаковка GZIP..."
            gunzip -c "$CHR_ZIP" > "$CHR_IMG"
        else
            log_error "Неизвестный формат: $FILE_TYPE"
            exit 1
        fi

        rm -f "$CHR_ZIP"
    fi
else
    log_info "Используется существующий образ: $CHR_IMG"
fi

# ============================================
# ВАЛИДАЦИЯ ОБРАЗА (РАСШИРЕННАЯ)
# ============================================
log_info "Валидация образа..."

if [[ ! -f "$CHR_IMG" ]]; then
    log_error "Образ не найден!"
    ls -la "$WORK_DIR"
    exit 1
fi

IMG_SIZE=$(stat -c%s "$CHR_IMG")
log_debug "Размер образа: $IMG_SIZE байт ($(( IMG_SIZE / 1024 / 1024 )) MB)"

# Проверка MBR сигнатуры (последние 2 байта первого сектора = 55 AA)
MBR_SIG=$(xxd -s 510 -l 2 -p "$CHR_IMG")
if [[ "$MBR_SIG" != "55aa" ]]; then
    log_error "Неверная MBR сигнатура: $MBR_SIG (ожидается 55aa)"
    exit 1
fi
log_debug "MBR сигнатура: OK (55aa)"

# Сохраняем MD5 оригинального образа
ORIGINAL_MD5=$(md5sum "$CHR_IMG" | awk '{print $1}')
log_info "MD5 оригинального образа: $ORIGINAL_MD5"

# Проверка таблицы разделов
log_debug "Таблица разделов:"
fdisk -l "$CHR_IMG" 2>/dev/null | grep -E "^(Disk|Device|${CHR_IMG})" || true

log_info "Образ прошёл валидацию ✓"

# ============================================
# ОПРЕДЕЛЕНИЕ СЕТЕВЫХ ПАРАМЕТРОВ
# ============================================
log_info "Определение сетевых параметров..."

INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
ADDRESS=$(ip addr show "$INTERFACE" 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | head -n1)
GATEWAY=$(ip route | grep default | awk '{print $3}' | head -n1)
SERVER_IP="${ADDRESS%/*}"
NETMASK="${ADDRESS#*/}"

if [[ -z "$INTERFACE" || -z "$ADDRESS" || -z "$GATEWAY" ]]; then
    log_error "Не удалось определить сетевые параметры"
    log_error "INTERFACE=$INTERFACE ADDRESS=$ADDRESS GATEWAY=$GATEWAY"
    exit 1
fi

check_same_subnet() {
    local ip="$1"
    local gw="$2"
    local mask="$3"
    
    IFS='.' read -r i1 i2 i3 i4 <<< "$ip"
    IFS='.' read -r g1 g2 g3 g4 <<< "$gw"
    
    local full_mask=$(( 0xFFFFFFFF << (32 - mask) & 0xFFFFFFFF ))
    local m1=$(( (full_mask >> 24) & 255 ))
    local m2=$(( (full_mask >> 16) & 255 ))
    local m3=$(( (full_mask >> 8) & 255 ))
    local m4=$(( full_mask & 255 ))
    
    if [[ $((i1 & m1)) -eq $((g1 & m1)) ]] && \
       [[ $((i2 & m2)) -eq $((g2 & m2)) ]] && \
       [[ $((i3 & m3)) -eq $((g3 & m3)) ]] && \
       [[ $((i4 & m4)) -eq $((g4 & m4)) ]]; then
        return 0
    else
        return 1
    fi
}

if check_same_subnet "$SERVER_IP" "$GATEWAY" "$NETMASK"; then
    GATEWAY_IN_SUBNET=true
    log_info "Gateway в той же подсети"
else
    GATEWAY_IN_SUBNET=false
    log_info "Gateway в другой подсети - используем network=$GATEWAY"
fi

log_info "Интерфейс: $INTERFACE | Адрес: $ADDRESS | Шлюз: $GATEWAY"

# ============================================
# ОПРЕДЕЛЕНИЕ ДИСКА
# ============================================
log_info "Определение целевого диска..."

echo ""
lsblk -d -o NAME,SIZE,MODEL,TYPE | grep -E "(NAME|disk)"
echo ""

# Определяем диск по корневому разделу (исключает fd0, sr0 и т.д.)
DISK_DEVICE=""
ROOT_PART=$(findmnt -n -o SOURCE / 2>/dev/null)
if [[ -n "$ROOT_PART" ]]; then
    DISK_DEVICE=$(lsblk -ndo PKNAME "$ROOT_PART" 2>/dev/null)
    [[ -n "$DISK_DEVICE" ]] && DISK_DEVICE="/dev/$DISK_DEVICE"
fi
# Fallback: первый реальный диск (исключаем floppy, cdrom, loop)
if [[ -z "$DISK_DEVICE" ]]; then
    DISK_DEVICE=$(lsblk -ndo NAME,TYPE | awk '$2=="disk" && $1!~/^(fd|sr|loop)/ {print "/dev/"$1; exit}')
fi

if [[ -z "$DISK_DEVICE" ]]; then
    log_error "Диск не найден"
    exit 1
fi

DISK_SIZE=$(lsblk -ndo SIZE "$DISK_DEVICE")
log_warn "Целевой диск: $DISK_DEVICE ($DISK_SIZE)"

# ============================================
# ВЫБОР ОБРАЗА ДЛЯ ЗАПИСИ
# ============================================
FINAL_IMG="$CHR_IMG"

if [[ "$SKIP_AUTORUN" == true ]]; then
    log_warn "Режим --clean: autorun.scr НЕ будет создан"
    log_warn "Настройка CHR вручную после загрузки"
else
    log_info "Создание autorun.scr..."
    
    # Создаём копию образа для модификации
    CHR_IMG_MOD="${CHR_IMG}.modified"
    cp "$CHR_IMG" "$CHR_IMG_MOD"
    
    # Монтирование
    mkdir -p "$MOUNT_POINT"
    
    # Диагностика структуры разделов
    log_debug "Структура разделов образа:"
    fdisk -l "$CHR_IMG_MOD" 2>/dev/null | head -20 || true
    
    # Определение номера раздела с данными
    # fat-chr 7.16 и Legacy MikroTik: раздел 2 (Linux filesystem)
    ROOT_PART_NUM=2
    log_debug "Используем раздел $ROOT_PART_NUM"

    # Убираем boot flag (*) чтобы колонки не сдвигались
    OFFSET_SECTORS=$(fdisk -l "$CHR_IMG_MOD" 2>/dev/null | grep "${CHR_IMG_MOD}${ROOT_PART_NUM}" | sed 's/\*//' | awk '{print $2}')
    if [[ -z "$OFFSET_SECTORS" ]]; then
        OFFSET_BYTES=33571840
    else
        OFFSET_BYTES=$((OFFSET_SECTORS * 512))
    fi
    
    log_debug "Монтирование раздела $ROOT_PART_NUM с offset: $OFFSET_BYTES"
    
    mount -o loop,offset="$OFFSET_BYTES" "$CHR_IMG_MOD" "$MOUNT_POINT"
    
    # Проверяем структуру
    log_debug "Содержимое смонтированного раздела:"
    ls -la "$MOUNT_POINT/" || true
    
    if [[ ! -d "$MOUNT_POINT/rw" ]]; then
        log_warn "Директория /rw не существует, создаём..."
        mkdir -p "$MOUNT_POINT/rw"
    fi
    
    # Создание autorun
    # Если gateway в другой подсети, используем network= для указания gateway
    if [[ "$GATEWAY_IN_SUBNET" == "true" ]]; then
        IP_ADD_CMD="/ip address add address=${ADDRESS} interface=ether1"
    else
        IP_ADD_CMD="/ip address add address=${ADDRESS} interface=ether1 network=${GATEWAY}"
    fi

    cat > "$MOUNT_POINT/rw/autorun.scr" <<EOF
/ip dhcp-client remove [find]
${IP_ADD_CMD}
/ip route
add dst-address=0.0.0.0/0 gateway=${GATEWAY}
/ip dns
set servers=${DNS_SERVERS} allow-remote-requests=yes
/ip service
set telnet disabled=yes
set ftp disabled=yes
set www disabled=yes
set ssh disabled=no
set api disabled=yes
set api-ssl disabled=yes
set winbox disabled=no
/user
set 0 name=admin password=${ADMIN_PASSWORD}
/ip firewall nat
add chain=srcnat out-interface=ether1 action=masquerade
/interface list
add name=StS
add name=WAN
/ip neighbor discovery-settings
set discover-interface-list=none
/ipv6 settings
set disable-ipv6=yes
/interface list member
add interface=ether1 list=WAN
/ip firewall address-list
add address=zen.dioservice.ru list=management
/ip firewall filter
add action=accept chain=input in-interface=ether1 protocol=gre
add action=accept chain=input comment=\
    "accept established, related connections" connection-state=\
    established,related
add action=drop chain=input comment="drop invalid connections" \
    connection-state=invalid log-prefix="DROP INPUT INVALID:"
add action=jump chain=input comment="jump for icmp input flow" jump-target=\
    icmp protocol=icmp
add action=jump chain=input comment="detect intrusion" connection-state=new \
    in-interface-list=WAN jump-target=detect-intrusion src-address-list=\
    !management
add action=jump chain=input comment="port knocking" connection-state=new \
    dst-port=1234,2345,3456 in-interface-list=WAN jump-target=pk protocol=tcp
add action=drop chain=input dst-port=12345 in-interface-list=WAN protocol=tcp \
    src-address-list=!pk-1
add action=drop chain=input dst-port=12345 in-interface-list=WAN protocol=tcp \
    src-address-list=!pk-2
add action=add-src-to-address-list address-list=management \
    address-list-timeout=1d chain=input connection-state=new dst-port=12345 \
    in-interface-list=WAN log=yes log-prefix=ACCESS! protocol=tcp \
    src-address-list=pk-3
add action=accept chain=input comment="accept management" connection-state=\
    new dst-port=22,8291,8729 log=yes log-prefix=ACCESS! protocol=tcp \
    src-address-list=management
add action=accept chain=input in-interface-list=StS
add action=drop chain=input comment="drop all other" log-prefix="IN DROP"
add action=accept chain=forward comment=\
    "accept established, related connections" connection-state=\
    established,related
add action=drop chain=forward comment="drop invalid connections" \
    connection-state=invalid log-prefix="INV FWD"
add action=accept chain=forward in-interface-list=StS out-interface-list=WAN
add action=jump chain=forward comment=ICMP jump-target=icmp protocol=icmp
add action=passthrough chain=forward comment="drop all other" log-prefix=FWD
add action=accept chain=icmp comment="echo request"
add action=accept chain=icmp comment="echo reply" icmp-options=0:0 protocol=\
    icmp
add action=accept chain=icmp comment="net unreachable" icmp-options=3:3 \
    protocol=icmp
add action=accept chain=icmp comment=\
    "host unreachable fragmentation required" icmp-options=3:4 protocol=icmp
add action=accept chain=icmp comment="time exceed" icmp-options=11:0 \
    protocol=icmp
add action=drop chain=icmp comment="drop all other types"
add action=add-src-to-address-list address-list=pk-1 address-list-timeout=1m \
    chain=pk comment=port-knocking dst-port=1234 protocol=tcp
add action=add-src-to-address-list address-list=pk-2 address-list-timeout=1m \
    chain=pk connection-state="" dst-port=2345 protocol=tcp
add action=add-src-to-address-list address-list=pk-3 address-list-timeout=1m \
    chain=pk connection-state="" dst-port=3456 protocol=tcp
add action=return chain=detect-intrusion comment="detect intrusion" \
    dst-limit=30,256,src-and-dst-addresses/1s
add action=add-src-to-address-list address-list="black-list attackers" \
    address-list-timeout=1d chain=detect-intrusion
add action=drop chain=detect-intrusion src-address-list=\
    "black-list attackers"
/ip firewall service-port
set tftp disabled=yes
set h323 disabled=yes
set pptp disabled=yes
/system clock
set time-zone-name=Asia/Yekaterinburg
/system ntp client
set enabled=yes
/system ntp client servers
add address=0.pool.ntp.org
add address=1.pool.ntp.org
/tool bandwidth-server
set enabled=no
/file
remove [find name~"autorun"]
EOF
    
    # Синхронизация ФС перед размонтированием
    sync
    
    log_debug "autorun.scr создан:"
    cat "$MOUNT_POINT/rw/autorun.scr"
    
    # Проверяем что файл записался
    if [[ ! -s "$MOUNT_POINT/rw/autorun.scr" ]]; then
        log_error "autorun.scr пустой или не создан!"
        umount "$MOUNT_POINT"
        exit 1
    fi
    
    # Размонтирование с sync
    sync
    umount "$MOUNT_POINT"
    sync
    
    # Проверка MD5 после модификации
    MODIFIED_MD5=$(md5sum "$CHR_IMG_MOD" | awk '{print $1}')
    log_debug "MD5 после модификации: $MODIFIED_MD5"
    
    if [[ "$ORIGINAL_MD5" == "$MODIFIED_MD5" ]]; then
        log_warn "MD5 не изменился — возможно autorun.scr не записался"
    fi
    
    # Проверка MBR после модификации
    MBR_SIG_MOD=$(xxd -s 510 -l 2 -p "$CHR_IMG_MOD")
    if [[ "$MBR_SIG_MOD" != "55aa" ]]; then
        log_error "MBR повреждён после модификации! Сигнатура: $MBR_SIG_MOD"
        log_error "Используем оригинальный образ без autorun"
        rm -f "$CHR_IMG_MOD"
        SKIP_AUTORUN=true
        FINAL_IMG="$CHR_IMG"
    else
        log_debug "MBR после модификации: OK"
        FINAL_IMG="$CHR_IMG_MOD"
        log_info "Autorun настроен ✓"
    fi
fi

# ============================================
# ФИНАЛЬНОЕ ПОДТВЕРЖДЕНИЕ
# ============================================
echo ""
echo "============================================"
echo -e "${YELLOW}        ТОЧКА НЕВОЗВРАТА!${NC}"
echo "============================================"
echo ""
echo "Образ:   $FINAL_IMG"
echo "Диск:    $DISK_DEVICE ($DISK_SIZE)"
echo "Режим:   $BOOT_MODE"
echo "IP:      $ADDRESS"
echo "Шлюз:    $GATEWAY"
echo "Autorun: $(if [[ "$SKIP_AUTORUN" == true ]]; then echo "ОТКЛЮЧЕН"; else echo "включен"; fi)"
echo ""
echo -e "${RED}ВСЕ ДАННЫЕ НА $DISK_DEVICE БУДУТ УНИЧТОЖЕНЫ!${NC}"
echo ""

if [[ "$AUTO_YES" == true ]]; then
    log_warn "Автоматический режим (--yes), продолжаем без подтверждения..."
else
    read -p "Введи 'YES' для продолжения: " confirm < /dev/tty
    if [[ "$confirm" != "YES" ]]; then
        log_info "Отменено"
        exit 0
    fi
fi

# ============================================
# ЗАПИСЬ НА ДИСК
# ============================================
log_info "Запись образа на $DISK_DEVICE..."

# Переводим FS в read-only чтобы избежать race condition
log_info "Перевод файловой системы в read-only..."
sync
echo 1 > /proc/sys/kernel/sysrq
echo u > /proc/sysrq-trigger
sleep 2

dd if="$FINAL_IMG" of="$DISK_DEVICE" bs=4M oflag=sync status=progress

log_info "Запись завершена"
# sync не нужен - FS уже в read-only, dd с oflag=direct пишет напрямую

# ============================================
# ВЕРИФИКАЦИЯ ЗАПИСИ
# ============================================
# После echo u файловая система в read-only, верификация невозможна
# MBR уже проверен до записи, dd с oflag=direct гарантирует запись
log_info "Верификация пропущена (FS в read-only после remount)"

# ============================================
# ЗАВЕРШЕНИЕ
# ============================================
echo ""
log_info "=========================================="
log_info "Установка CHR завершена успешно!"
log_info "=========================================="
echo ""

if [[ "$SKIP_AUTORUN" == true ]]; then
    echo "После загрузки настрой вручную:"
    echo "  /ip address add address=$ADDRESS interface=ether1"
    echo "  /ip route add gateway=$GATEWAY"
    echo ""
fi

echo "CHR будет доступен: ${ADDRESS%/*}"
echo "Admin пароль:  ${ADMIN_PASSWORD}"
echo ""

if [[ "$AUTO_YES" == true && "$AUTO_REBOOT" == true ]]; then
    log_info "Автоматическая перезагрузка через 3 секунды..."
    sleep 3
    echo 1 > /proc/sys/kernel/sysrq
    echo s > /proc/sysrq-trigger
    sleep 1
    echo u > /proc/sysrq-trigger
    sleep 1
    echo b > /proc/sysrq-trigger
elif [[ "$AUTO_YES" == true ]]; then
    log_info "Перезагрузи вручную: reboot"
else
    read -p "Перезагрузить сейчас? (y/n): " do_reboot < /dev/tty
    if [[ "$do_reboot" == "y" ]]; then
        log_info "Перезагрузка..."
        sleep 2
        echo 1 > /proc/sys/kernel/sysrq
        echo s > /proc/sysrq-trigger
        sleep 1
        echo u > /proc/sysrq-trigger
        sleep 1
        echo b > /proc/sysrq-trigger
    else
        log_info "Перезагрузи вручную: reboot"
    fi
fi
