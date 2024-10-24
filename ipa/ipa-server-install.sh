#!/bin/bash

IPA_SERVER_HOSTNAME=ipa.example.com
IPA_SERVER_IP=$(hostname -I | awk '{print $1}')
DOMAIN=example.com
REALM=EXAMPLE.COM
PASSWORD=admin_password
LOGFILE="/var/log/ipaserver-install.log"

echo "Starting FreeIPA server installation..."

ipa-server-install -U \
    --skip-mem-check \
    --hostname=${IPA_SERVER_HOSTNAME} \
    --domain=${DOMAIN} \
    --realm=${REALM} \
    --ds-password=${PASSWORD} \
    --admin-password=${PASSWORD} \
    --ip-address=${IPA_SERVER_IP} \
    --setup-dns \
    --no-forwarders \
    --allow-zone-overlap > ${LOGFILE} 2>&1

if [ $? -eq 0 ]; then
    # echo "session required pam_mkhomedir.so skel=/etc/skel/ umask=0077" >> /etc/pam.d/system-auth
    echo "FreeIPA server installation completed successfully."
else
    echo "FreeIPA server installation failed. Check the logfile at ${LOGFILE} for details."
fi