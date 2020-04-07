#! /usr/bin/env bash
set -e

sudo sed -i -e '/local.*peer/s/postgres/all/' -e 's/peer\|md5/trust/g' /etc/postgresql/*/main/pg_hba.conf
# for some reason this command returns failure code but still succeeds...
sudo service postgresql restart || true
psql -U postgres -c 'SELECT version()'

if [ ! -f "vendor/bin/dbmate" ]; then
  mkdir -p vendor/bin
  wget -qO vendor/bin/dbmate https://github.com/amacneil/dbmate/releases/download/v1.7.0/dbmate-linux-amd64
  chmod +x vendor/bin/dbmate
fi
