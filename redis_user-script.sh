#!/bin/bash -x

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Copyright 2020 Joyent, Inc.

# If the redis-sentinel service is already exists, everything should be ok.
svcs -H redis-sentinel && exit 0

export PATH=/opt/local/bin:/opt/local/sbin:$PATH

if [[ -n "$TRACE" ]]; then
    export PS4='[\D{%FT%TZ}] ${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
    set -o xtrace
fi

function stack_trace
{
    set +o xtrace

    (( cnt = ${#FUNCNAME[@]} ))
    (( i = 0 ))
    while (( i < cnt )); do
        printf '  [%3d] %s\n' "${i}" "${FUNCNAME[i]}"
        if (( i > 0 )); then
            line="${BASH_LINENO[$((i - 1))]}"
        else
            line="${LINENO}"
        fi
        printf '        (file "%s" line %d)\n' "${BASH_SOURCE[i]}" "${line}"
        (( i++ ))
    done
}

function fatal
{
    # Disable error traps from here on:
    set +o xtrace
    set +o errexit
    set +o errtrace
    trap '' ERR

    echo "$(basename "$0"): fatal error: $*" >&2
    stack_trace
    exit 1
}

function trap_err
{
    st=$?
    fatal "exit status ${st} at line ${BASH_LINENO[0]}"
}


# We set errexit (a.k.a. "set -e") to force an exit on error conditions, but
# there are many important error conditions that this does not capture --
# first among them failures within a pipeline (only the exit status of the
# final stage is propagated).  To exit on these failures, we also set
# "pipefail" (a very useful option introduced to bash as of version 3 that
# propagates any non-zero exit values in a pipeline).
#
set -o errexit
set -o pipefail

shopt -s extglob

#
# Install our error handling trap, so that we can have stack traces on
# failures.  We set "errtrace" so that the ERR trap handler is inherited
# by each function call.
#
trap trap_err ERR
set -o errtrace

token=$(mdata-get redis_token)

svc_name="$(mdata-get svc_name)"
network_name="$(mdata-get network_name)"
dns_domain=$(mdata-get sdc:dns_domain)
svc_domain="${dns_domain/inst/svc}"

peers=()
while IFS='' read -r line; do peers+=("$line"); done < <(
    dig +short "${network_name}.${svc_name}.${svc_domain}"
)
self=$(mdata-get sdc:nics | json -ac 'this.nic_tag.match(/sdc_overlay/)' ip)

mkdir -p /opt/custom/smf

init_patch="--- redis.conf.orig     2025-12-29 22:57:34.368329873 +0000
+++ redis.conf  2025-12-29 23:09:35.691209850 +0000
@@ -84,7 +84,6 @@
 # You will also need to set a password unless you explicitly disable protected
 # mode.
 # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-bind 127.0.0.1 -::1

 # By default, outgoing connections (from replica to master, from Sentinel to
 # instances, cluster bus, etc.) are not bound to a specific local address. In
@@ -538,7 +537,8 @@
 # refuse the replica request.
 #
 # masterauth <master-password>
-#
+masterauth $token
+
 # However this is not enough if you are using Redis ACLs (for Redis version
 # 6 or greater), and the default user is not capable of running the PSYNC
 # command and/or other commands needed for replication. In this case it's
@@ -1041,7 +1041,7 @@
 # The requirepass is not compatible with aclfile option and the ACL LOAD
 # command, these will cause requirepass to be ignored.
 #
-# requirepass foobared
+requirepass $token

 # New users are initialized with restrictive permissions by default, via the
 # equivalent of this ACL rule 'off resetkeys -@all'. Starting with Redis 6.2, it
 #"

# shellcheck disable=2140
join_patch="
--- redis.conf.orig     2025-12-29 23:22:16.212801197 +0000
+++ redis.conf  2025-12-29 23:25:12.520317611 +0000
@@ -84,7 +84,6 @@
 # You will also need to set a password unless you explicitly disable protected
 # mode.
 # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-bind 127.0.0.1 -::1

 # By default, outgoing connections (from replica to master, from Sentinel to
 # instances, cluster bus, etc.) are not bound to a specific local address. In
@@ -531,6 +530,7 @@
 #    and resynchronize with them.
 #
 # replicaof <masterip> <masterport>
+replicaof ${peers[0]} 6379

 # If the master is password protected (using the "requirepass" configuration
 # directive below) it is possible to tell the replica to authenticate before
@@ -538,7 +538,8 @@
 # refuse the replica request.
 #
 # masterauth <master-password>
-#
+masterauth $token
+
 # However this is not enough if you are using Redis ACLs (for Redis version
 # 6 or greater), and the default user is not capable of running the PSYNC
 # command and/or other commands needed for replication. In this case it's
@@ -1042,6 +1043,7 @@
 # command, these will cause requirepass to be ignored.
 #
 # requirepass foobared
+requirepass $token

 # New users are initialized with restrictive permissions by default, via the
 # equivalent of this ACL rule 'off resetkeys -@all'. Starting with Redis 6.2, it
 #"

if (( ${#peers[@]} == 0 )); then
	primary="$self"
	patch="$init_patch"
else
	primary="${peers[0]}"
	patch="$join_patch"
fi

pkgin -y install redis tmux

mkdir -p /opt/local/etc/redis

mv /opt/local/etc/redis.conf /opt/local/etc/redis/redis.conf

patch /opt/local/etc/redis/redis.conf <<< "$patch"

cat > /opt/local/etc/redis/sentinel.conf << EOF
bind $self
port 26379
daemonize yes
dir /var/db/redis
pidfile /var/db/redis/sentinel.pid
logfile /var/log/redis/sentinel.log

sentinel monitor $svc_name $primary 6379 2
sentinel auth-pass $svc_name $token
sentinel down-after-milliseconds $svc_name 10000
sentinel parallel-syncs $svc_name 1
EOF

cat > /opt/custom/smf/redis-sentinel.xml << EOF
<?xml version="1.0"?>
<!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
<!-- This Source Code Form is subject to the terms of the Mozilla Public
   - License, v. 2.0. If a copy of the MPL was not distributed with this
   - file, You can obtain one at https://mozilla.org/MPL/2.0/. -->
<service_bundle type="manifest" name="export">
  <service name="pkgsrc/redis-sentinel" type="service" version="1">
    <create_default_instance enabled="false" />
    <single_instance />
    <dependency name="network" grouping="require_all" restart_on="error" type="service">
      <service_fmri value="svc:/milestone/network:default" />
    </dependency>
    <dependency name="filesystem" grouping="require_all" restart_on="error" type="service">
      <service_fmri value="svc:/system/filesystem/local" />
    </dependency>
    <method_context working_directory="/var/db/redis">
      <method_credential user="redis" group="redis" />
    </method_context>
    <exec_method type="method" name="start" exec="/opt/local/bin/redis-server %{config_file} --sentinel" timeout_seconds="60" />
    <exec_method type="method" name="stop" exec=":kill" timeout_seconds="60" />
    <property_group name="startd" type="framework">
      <propval name="duration" type="astring" value="contract" />
      <propval name="ignore_error" type="astring" value="core,signal" />
    </property_group>
    <property_group name="application" type="application">
      <propval name="config_file" type="astring" value="/opt/local/etc/redis/sentinel.conf" />
    </property_group>
    <template>
      <common_name>
        <loctext xml:lang="C">Redis server</loctext>
      </common_name>
    </template>
  </service>
</service_bundle>
EOF

cat > /opt/custom/smf/redis.xml << EOF
<?xml version='1.0'?>
<!DOCTYPE service_bundle SYSTEM '/usr/share/lib/xml/dtd/service_bundle.dtd.1'>
<service_bundle type='manifest' name='export'>
  <service name='pkgsrc/redis' type='service' version='1'>
    <create_default_instance enabled='false'/>
    <single_instance/>
    <dependency name='network' grouping='require_all' restart_on='error' type='service'>
      <service_fmri value='svc:/milestone/network:default'/>
    </dependency>
    <dependency name='filesystem' grouping='require_all' restart_on='error' type='service'>
      <service_fmri value='svc:/system/filesystem/local'/>
    </dependency>
    <method_context working_directory='/var/db/redis' project='redis'>
      <method_credential group='redis' user='redis'/>
    </method_context>
    <exec_method name='start' type='method' exec='/opt/local/bin/redis-server %{config_file}' timeout_seconds='60'/>
    <exec_method name='stop' type='method' exec=':kill' timeout_seconds='60'/>
    <property_group name='startd' type='framework'>
      <propval name='duration' type='astring' value='contract'/>
      <propval name='ignore_error' type='astring' value='core,signal'/>
    </property_group>
    <property_group name='application' type='application'>
      <propval name='config_file' type='astring' value='/opt/local/etc/redis/redis.conf'/>
    </property_group>
    <template>
      <common_name>
        <loctext xml:lang='C'>Redis server</loctext>
      </common_name>
    </template>
  </service>
</service_bundle>
EOF

chown redis:redis /opt/local/etc/redis/
chown redis:redis /opt/local/etc/redis/{redis,sentinel}.conf

svccfg import /opt/custom/smf/redis-sentinel.xml
svccfg import /opt/custom/smf/redis.xml
svcadm enable redis-sentinel
sleep 2
svcadm enable redis
mdata-delete triton.cns.status
