#! /usr/bin/env bash
set -e

sudo sed -i -e '/local.*peer/s/postgres/all/' -e 's/peer\|md5/trust/g' /etc/postgresql/*/main/pg_hba.conf
# for some reason this command returns failure code but still succeeds...
sudo service postgresql restart || true
psql -U postgres -c 'SELECT version()'

make vendor/bin/dbmate
