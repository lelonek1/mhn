#!/bin/bash

set -e
set -x

if [ $# -lt 2 ]
    then
        echo "Wrong number of arguments supplied."
        echo "Usage: $0 <server_url> <deploy_key> [log-as-kippo] [disable-kippo]"
        exit 1
fi

server_url=$1
deploy_key=$2

hpname=cowrie

if [ "$3" = "log-as-kippo" -o "$4" = "log-as-kippo" ]
    then
        hpname=kippo
fi

if [ "$3" = "disable-kippo" -o "$4" = "disable-kippo" ]
    then
        disable_kippo="true"
fi

wget $server_url/static/registration.txt -O registration.sh
chmod 755 registration.sh
# Note: this will export the HPF_* variables
. ./registration.sh $server_url $deploy_key "$hpname"

apt-get update
apt-get -y install python-dev openssl python-openssl python-pyasn1 python-twisted git python-pip supervisor authbind


# Change real SSH Port to 2222
sed -i 's/Port 22$/Port 2222/g' /etc/ssh/sshd_config && \
service ssh restart || echo "WARNING: Could not change real SSH Port"

# Create cowrie user
useradd -d /home/cowrie -s /bin/bash -m cowrie -g users

# Get the Cowrie source
cd /opt
git clone https://github.com/micheloosterhof/cowrie
cd cowrie

# Change the channel in Cowrie's source to log as Kippo
if [ "$hpname" = "kippo" ]
    then
        sed -i 's/cowrie\.sessions/kippo\.sessions/g' /opt/cowrie/cowrie/dblog/hpfeeds.py
fi

# Determine if IPTables forwarding is going to work
# Capture stdout, if there there is something there, then the command failed
if [ -z "$(sysctl -w net.ipv4.conf.eth0.route_localnet=1 2>&1 >/dev/null)" ]
    then
        iptable_support=true
        echo "Adding iptables port forwarding rule...\n"
        iptables -F -t nat
        iptables -t nat -A PREROUTING -i eth0 -p tcp -m tcp --dport 22 -j DNAT --to-destination 127.0.0.1:64222
        
        echo "net.ipv4.conf.eth0.route_localnet=1" > /etc/sysctl.conf
        DEBIAN_FRONTEND=noninteractive  apt-get install -q -y iptables-persistent
    else
        iptable_support=false
fi
echo "iptable_support: $iptable_support"

# Configure Cowrie

HONEYPOT_HOSTNAME="db01"
HONEYPOT_SSH_VERSION="SSH-2.0-OpenSSH_5.5p1 Debian-4ubuntu5"

if $iptable_support; 
then
    cat > /opt/cowrie/cowrie.cfg <<EOF
[honeypot]
listen_port = 64222
listen_addr = 127.0.0.1
reported_ssh_port = 22
EOF

else
    cat > /opt/cowrie/cowrie.cfg <<EOF
[honeypot]
listen_addr = 22
EOF

fi

cat >> /opt/cowrie/cowrie.cfg <<EOF
hostname = ${HONEYPOT_HOSTNAME}
log_path = log
download_path = dl
contents_path = honeyfs
filesystem_file = data/fs.pickle
data_path = data
txtcmds_path = txtcmds
rsa_public_key = data/ssh_host_rsa_key.pub
rsa_private_key = data/ssh_host_rsa_key
dsa_public_key = data/ssh_host_dsa_key.pub
dsa_private_key = data/ssh_host_dsa_key
ssh_version_string = ${HONEYPOT_SSH_VERSION}
interact_enabled = false
interact_port = 5123

auth_class = UserDB
exec_enabled = true
sftp_enabled = true


[database_hpfeeds]
server = $HPF_HOST
port = $HPF_PORT
identifier = $HPF_IDENT
secret = $HPF_SECRET
debug = false
EOF


# Fix permissions for Cowrie
chown -R cowrie:users /opt/cowrie
touch /etc/authbind/byport/22
chown cowrie /etc/authbind/byport/22
chmod 777 /etc/authbind/byport/22


# Setup Cowrie to start at boot
cp start.sh start.sh.backup
if $iptable_support; 
then
    cat > start.sh <<EOF
#!/bin/sh

cd /opt/cowrie
exec /usr/bin/twistd -n -l log/cowrie.log --pidfile cowrie.pid cowrie
EOF

else
    cat > start.sh <<EOF
#!/bin/sh

cd /opt/cowrie
su cowrie -c "authbind --deep twistd -n -l log/cowrie.log --pidfile cowrie.pid cowrie
EOF

fi
chmod +x start.sh

# Config for supervisor.
if $iptable_support; 
then
    cat > /etc/supervisor/conf.d/cowrie.conf <<EOF
[program:cowrie]
command=/opt/cowrie/start.sh
directory=/opt/cowrie
stdout_logfile=/opt/cowrie/log/cowrie.out
stderr_logfile=/opt/cowrie/log/cowrie.err
autostart=true
autorestart=true
redirect_stderr=true
stopsignal=KILL
user=cowrie
stopasgroup=true
EOF
else
    cat > /etc/supervisor/conf.d/cowrie.conf <<EOF
[program:cowrie]
command=/opt/cowrie/start.sh
directory=/opt/cowrie
stdout_logfile=/opt/cowrie/log/cowrie.out
stderr_logfile=/opt/cowrie/log/cowrie.err
autostart=true
autorestart=true
redirect_stderr=true
stopsignal=QUIT
EOF
fi

# Attempt to disable the existing Kippo installation
if [ "$disable_kippo" = "true" ]
    then
        rm -f /etc/supervisor/conf.d/kippo.conf && \
            echo "Successfully disabled Kippo" || \
            echo "WARNING: Could not disable Kippo"
fi

supervisorctl update
