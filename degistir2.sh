#!/bin/bash

# MySQL Link Find and Replace Script
# Veritabanlarındaki link verilerini değiştirme ve yedekleme

# Renkli çıktı
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   MySQL Link Değiştirme Aracı${NC}"
echo -e "${BLUE}========================================${NC}"
echo

# MySQL şifresini al
MYSQL_PASSWORD=""
if [ -f "/root/.my.cnf" ]; then
    MYSQL_PASSWORD=$(grep -E "^password=" /root/.my.cnf | cut -d'=' -f2- | tr -d '"' | tr -d "'" | xargs)
    if [ -n "$MYSQL_PASSWORD" ]; then
        echo -e "${GREEN}✓ MySQL şifresi /root/.my.cnf dosyasından alındı${NC}"
    fi
fi

if [ -z "$MYSQL_PASSWORD" ]; then
    echo -e "${YELLOW}⚠ MySQL root şifresi bulunamadı${NC}"
    read -sp "MySQL root şifresini girin: " MYSQL_PASSWORD
    echo
fi

# MySQL bağlantı testi
if ! mysql -u root -p"$MYSQL_PASSWORD" -e "SELECT 1;" &>/dev/null; then
    echo -e "${RED}✗ Hata: MySQL bağlantısı başarısız!${NC}"
    exit 1
fi

echo -e "${GREEN}✓ MySQL bağlantısı başarılı${NC}"
echo

# Sistem veritabanlarını hariç tut
EXCLUDED_DBS="information_schema performance_schema mysql sys phpmyadmin roundcube"

echo -e "${CYAN}ℹ Hariç tutulan veritabanları:${NC}"
echo "  $EXCLUDED_DBS"
echo

# Eski linki al
read -p "Değiştirilecek link (Eski): " OLD_LINK
if [ -z "$OLD_LINK" ]; then
    echo -e "${RED}✗ Link boş olamaz!${NC}"
    exit 1
fi

# Yeni linki al
read -p "Yeni link: " NEW_LINK
if [ -z "$NEW_LINK" ]; then
    echo -e "${RED}✗ Link boş olamaz!${NC}"
    exit 1
fi

echo
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Eski Link: ${NC}$OLD_LINK"
echo -e "${YELLOW}Yeni Link: ${NC}$NEW_LINK"
echo -e "${YELLOW}========================================${NC}"
echo

# Onay al
read -p "Bu değişikliği yapmak istediğinizden emin misiniz? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo -e "${RED}İşlem iptal edildi${NC}"
    exit 0
fi

echo
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}İŞLEM BAŞLIYOR...${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo

# Yedek klasörü oluştur
BACKUP_DIR="/root/mysql_backups/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
echo -e "${CYAN}📦 Yedek klasörü: $BACKUP_DIR${NC}"
echo

# Veritabanlarını al
ALL_DBS=$(mysql -u root -p"$MYSQL_PASSWORD" -e "SHOW DATABASES;" | tail -n +2)
DATABASES=""

for DB in $ALL_DBS; do
    SKIP=0
    for EXCLUDED in $EXCLUDED_DBS; do
        if [ "$DB" == "$EXCLUDED" ]; then
            SKIP=1
            break
        fi
    done
    if [ $SKIP -eq 0 ]; then
        DATABASES="$DATABASES $DB"
    fi
done

TOTAL_REPLACED=0
TOTAL_TABLES_CHECKED=0
TOTAL_TABLES_UPDATED=0

# Escape karakterlerini hazırla
ESCAPED_OLD=$(echo "$OLD_LINK" | sed "s/'/\\\\'/g")
ESCAPED_NEW=$(echo "$NEW_LINK" | sed "s/'/\\\\'/g")

# Her veritabanı için döngü
for DB in $DATABASES; do
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}📁 Veritabanı: $DB${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Önce kontrol et: Bu veritabanında değiştirilecek veri var mı?
    echo -e "  ${CYAN}🔍 Değiştirilecek veri kontrol ediliyor...${NC}"

    # Tabloları al
    TABLES=$(mysql -u root -p"$MYSQL_PASSWORD" -D "$DB" -e "SHOW TABLES;" 2>/dev/null | tail -n +2)

    if [ -z "$TABLES" ]; then
        echo -e "  ${CYAN}ℹ Tablo bulunamadı${NC}"
        echo
        continue
    fi

    DB_HAS_DATA=0

    # Önce veritabanında değiştirilecek veri olup olmadığını kontrol et
    for TABLE in $TABLES; do
        COLUMNS=$(mysql -u root -p"$MYSQL_PASSWORD" -D "$DB" -e "
            SELECT COLUMN_NAME
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = '$DB'
            AND TABLE_NAME = '$TABLE'
            AND DATA_TYPE IN ('varchar', 'char', 'text', 'tinytext', 'mediumtext', 'longtext');" 2>/dev/null | tail -n +2)

        if [ -z "$COLUMNS" ]; then
            continue
        fi

        while read -r COLUMN; do
            # Bu kolonda aranacak veri var mı kontrol et
            COUNT=$(mysql -u root -p"$MYSQL_PASSWORD" -D "$DB" -e "SELECT COUNT(*) FROM \`$TABLE\` WHERE \`$COLUMN\` LIKE '%$ESCAPED_OLD%';" 2>/dev/null | tail -n 1)

            if [ "$COUNT" -gt 0 ] 2>/dev/null; then
                DB_HAS_DATA=1
                break 2
            fi
        done <<< "$COLUMNS"
    done

    # Eğer değiştirilecek veri yoksa, yedek alma ve işlem yapma
    if [ $DB_HAS_DATA -eq 0 ]; then
        echo -e "  ${CYAN}ℹ Bu veritabanında değiştirilecek veri bulunamadı (Yedek alınmadı)${NC}"
        echo
        continue
    fi

    # Değiştirilecek veri var, yedek al
    echo -e "  ${GREEN}✓ Değiştirilecek veri bulundu${NC}"
    echo -e "  ${CYAN}📦 Yedek alınıyor...${NC}"
    mysqldump -u root -p"$MYSQL_PASSWORD" "$DB" > "$BACKUP_DIR/${DB}.sql" 2>/dev/null

    if [ $? -eq 0 ]; then
        BACKUP_SIZE=$(du -h "$BACKUP_DIR/${DB}.sql" | cut -f1)
        echo -e "  ${GREEN}✓ Yedek tamamlandı ($BACKUP_SIZE)${NC}"
    else
        echo -e "  ${RED}✗ Yedek alınamadı! İşlem atlanıyor...${NC}"
        echo
        continue
    fi

    DB_HAS_UPDATE=0

    # Şimdi değişiklik yap
    for TABLE in $TABLES; do
        TOTAL_TABLES_CHECKED=$((TOTAL_TABLES_CHECKED + 1))

        # TEXT ve VARCHAR kolonları al
        COLUMNS=$(mysql -u root -p"$MYSQL_PASSWORD" -D "$DB" -e "
            SELECT COLUMN_NAME, DATA_TYPE
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = '$DB'
            AND TABLE_NAME = '$TABLE'
            AND DATA_TYPE IN ('varchar', 'char', 'text', 'tinytext', 'mediumtext', 'longtext');" 2>/dev/null | tail -n +2)

        if [ -z "$COLUMNS" ]; then
            continue
        fi

        TABLE_HAS_UPDATE=0

        # Her kolon için REPLACE işlemi
        while IFS=$'\t' read -r COLUMN DATA_TYPE; do
            # Önce kaç satır etkilenecek kontrol et
            COUNT_BEFORE=$(mysql -u root -p"$MYSQL_PASSWORD" -D "$DB" -e "SELECT COUNT(*) FROM \`$TABLE\` WHERE \`$COLUMN\` LIKE '%$ESCAPED_OLD%';" 2>/dev/null | tail -n 1)

            if [ -z "$COUNT_BEFORE" ] || [ "$COUNT_BEFORE" -eq 0 ] 2>/dev/null; then
                continue
            fi

            # UPDATE query'i çalıştır
            RESULT=$(mysql -u root -p"$MYSQL_PASSWORD" -D "$DB" -e "UPDATE \`$TABLE\` SET \`$COLUMN\` = REPLACE(\`$COLUMN\`, '$ESCAPED_OLD', '$ESCAPED_NEW') WHERE \`$COLUMN\` LIKE '%$ESCAPED_OLD%'; SELECT ROW_COUNT() as affected;" 2>/dev/null)

            ROWS_CHANGED=$(echo "$RESULT" | tail -n 1)

            if [ ! -z "$ROWS_CHANGED" ] && [ "$ROWS_CHANGED" -gt 0 ] 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} Tablo: ${BLUE}$TABLE${NC} | Kolon: ${BLUE}$COLUMN${NC} | ${GREEN}$ROWS_CHANGED satır güncellendi${NC}"
                TOTAL_REPLACED=$((TOTAL_REPLACED + ROWS_CHANGED))
                TABLE_HAS_UPDATE=1
                DB_HAS_UPDATE=1
            fi
        done <<< "$COLUMNS"

        if [ $TABLE_HAS_UPDATE -eq 1 ]; then
            TOTAL_TABLES_UPDATED=$((TOTAL_TABLES_UPDATED + 1))
        fi
    done

    echo
done

echo
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}🎉 İŞLEM TAMAMLANDI!${NC}"
echo -e "${GREEN}========================================${NC}"
echo
echo -e "${BLUE}📊 İSTATİSTİKLER:${NC}"
echo -e "  • Taranan tablo sayısı: $TOTAL_TABLES_CHECKED"
echo -e "  • Güncellenen tablo sayısı: $TOTAL_TABLES_UPDATED"
echo -e "  • ${GREEN}Toplam güncellenen satır: $TOTAL_REPLACED${NC}"
echo
echo -e "${CYAN}📦 YEDEKLER:${NC}"
echo -e "  • Yedek konumu: $BACKUP_DIR"
echo -e "  • ${YELLOW}Geri yüklemek için: mysql -u root -p[şifre] [veritabanı] < [yedek.sql]${NC}"
echo
echo -e "${GREEN}========================================${NC}"
