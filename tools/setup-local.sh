#!/usr/bin/env bash
set -euo pipefail
umask 077
cd -- "$(dirname -- "$0")/.."

if (( EUID == 0 )); then
    echo 'Run this command as your regular user. It uses sudo for MariaDB.' >&2
    exit 1
fi
for program in mariadb openssl python3 sudo; do
    if ! command -v "$program" >/dev/null; then
        echo "Missing $program. Install the dependencies in docs/SETUP.md." >&2
        exit 1
    fi
done

if [ ! -r sql/local/classicmangos.sql.gz ]; then
    echo 'Copy the world archive to sql/local/classicmangos.sql.gz. See docs/SETUP.md.' >&2
    exit 1
fi
if [ ! -f data/dbc/ChrRaces.dbc ] || [ ! -d data/maps ]; then
    echo 'Copy or extract the client data into data/dbc/ and data/maps/. See docs/SETUP.md.' >&2
    exit 1
fi
for config in authserver.json worldserver.json worldserver-member.json; do
    if [ -e "$config" ] || [ -L "$config" ]; then
        echo "$config already exists. Use the existing setup or back it up before a fresh install." >&2
        exit 1
    fi
done

existing=$(sudo mariadb -NBe "
    SELECT SCHEMA_NAME FROM information_schema.SCHEMATA
    WHERE SCHEMA_NAME IN ('classicrealmd', 'classiccharacters', 'classicmangos');
    SELECT User FROM mysql.user WHERE User='mangos' AND Host='127.0.0.1';
")
if [ -n "$existing" ]; then
    printf 'Existing MariaDB databases or user found:\n%s\n' "$existing" >&2
    echo 'Use a fresh MariaDB instance for this setup.' >&2
    exit 1
fi

db_password=$(openssl rand -hex 16)
config_dir=$(mktemp -d)
trap 'rm -rf -- "$config_dir"' EXIT

sed "s/;mangos;mangos;/;mangos;${db_password};/g" \
  config/authserver.example.json > "$config_dir/authserver.json"
sed -e "s/;mangos;mangos;/;mangos;${db_password};/g" \
  -e 's/"data_dir": "\."/"data_dir": "data"/' \
  config/worldserver.example.json > "$config_dir/worldserver.json"
python3 tools/cluster-member.py "$config_dir/worldserver.json" > "$config_dir/worldserver-member.json"

sudo tools/database.sh install sql/local/classicmangos.sql.gz
sudo mariadb <<SQL
CREATE USER 'mangos'@'127.0.0.1' IDENTIFIED BY '${db_password}';
GRANT ALL PRIVILEGES ON classicrealmd.* TO 'mangos'@'127.0.0.1';
GRANT ALL PRIVILEGES ON classiccharacters.* TO 'mangos'@'127.0.0.1';
GRANT ALL PRIVILEGES ON classicmangos.* TO 'mangos'@'127.0.0.1';
SQL

mv -- "$config_dir"/*.json .
mkdir -p logs
echo 'Database and server configs are ready.'
