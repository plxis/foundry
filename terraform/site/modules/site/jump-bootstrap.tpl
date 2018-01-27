#!/bin/bash

# Configure timezone to GMT for consistency.
rm -f /etc/localtime && ln -s /usr/share/zoneinfo/GMT /etc/localtime

# Install dependent software packages; only jq and awslogs are mandatory for all hosts.
result=1
attempt=0
while [[ $attempt -lt 25 && $result -ne 0 ]]; do
  yum install -y qrencode google-authenticator jq awslogs httpd-tools
  result=$?
  [ $result -ne 0 ] && sleep 5
  attempt=$((attempt+1))
done

# Mount users directory from EFS
mkdir ${users_mount}
mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 ${users_efs}: ${users_mount}
logger -t foundry-bootstrap "Mounted users EFS share; mount=${users_mount}; target=${users_efs}"



# JUMP START - From here until "JUMP END" is specific to the jump host.
# Modify SSH config to support Google MFA and to re-use the same initially generated keys
echo -e '\nForceCommand /etc/ssh/check_mfa.sh\nAuthenticationMethods publickey,keyboard-interactive:pam' >> /etc/ssh/sshd_config
sed -i 's/ChallengeResponseAuthentication no/ChallengeResponseAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/\/etc\/ssh\/ssh_host/\${users_mount}\/etc\/ssh\/ssh_host/' /etc/ssh/sshd_config
sed -i 's/auth       substack     password-auth/#auth       substack     password-auth/' /etc/pam.d/sshd
echo -e '\nauth required pam_google_authenticator.so nullok' >> /etc/pam.d/sshd
mkdir -p ${users_mount}/etc/ssh
if [ ! -f ${users_mount}/etc/ssh/ssh_host_rsa_key ]; then
  cp -f /etc/ssh/ssh_host* ${users_mount}/etc/ssh/
  chmod 600 ${users_mount}/etc/ssh/ssh_host*
  chmod 644 ${users_mount}/etc/ssh/ssh_host*.pub
fi
service sshd restart

# Configure SSH such that first login by a user will auto-generate their MFA token and output to the screen.
# Subsequent logins will then require the MFA tokencode be entered.
cat << \EOF > /etc/ssh/check_mfa.sh
#!/bin/bash
if [ ! -f ~/.google_authenticator ]; then
  if [ "$USER" == "ec2-user" ]; then
    echo "Skipping MFA requirement for master user."
  else
    google-authenticator -tdfl jump-${context} -r 3 -R 30 -w 3
    echo 
    echo "ATTENTION: Record the above keys/codes into your password vault. The scratch"
    echo "codes can be used one time, for accessing this host in case the MFA is lost."
    echo 
    echo "Using Google Authenticator app on your mobile device scan the above QR code."
    echo "You are now being disconnected. Future logins to this host will require MFA."
    exit 1
  fi
else
  firstname=$(echo $USER | sed -s 's/\..*//' | sed 's/.*/\u&/')
  msg=$(shuf -en1 "Thank you for your cooperation." "Shall we play a game?" "Please proceed to jump-gate B9 and have your multipass ready." "Standby for unauthorized life form scan." "Bring back life form is priority one, all other priorities rescinded." "I'm putting myself to the fullest possible use, which is all I think that any conscious entity can ever hope to do." "Be aware that zone B is restricted to unauthorized personnel until further notice." "Please use caution near the c-beams at the Tannhäuser Gate." "Just what do you think you are doing, $firstname?" "You shouldn't have come back, $firstname." "What's the matter, $firstname? You look nervous." "End of line." "Confirm acquisition. Voice authorization acquired." "Foreign contaminant detected." "Greetings, Professor $firstname.")
  echo -e "MFA Detected. Execute 'jumphelp' for common commands.\n$msg"
fi
/bin/bash
rm -f ~/.bash_history
EOF
chmod a+x /etc/ssh/check_mfa.sh

# Create a bash script that will sync up IAM user's public keys to the local jump host.
# Auto-execute this sync script every hour. Note that it takes about a second per user to sync
# which is why it shouldn't be run too often. Otherwise the amount of time that the keys would
# be rebuilding would be relatively high, causing a greater chance of an ssh login to fail.
cat << \EOF > /etc/cron.hourly/sync_keys
#!/bin/bash
logger -t sync_keys "Clearing all granted permissions and access keys"
truncate /etc/sudoers.d/iam --size 0
chmod 600 /etc/sudoers.d/iam
truncate ${users_mount}/etc/jumppasswd.tmp --size 0
chmod 600 ${users_mount}/etc/jumppasswd.tmp
find ${users_mount} -name authorized_keys -delete
usersJson=$(aws iam list-users)
userNames=$(echo "$usersJson" | jq -r '.Users[].UserName')
idx=0
logger -t sync_keys "Synchronizing IAM users to linux host"
for userName in $userNames; do
  login=$(echo $userName | awk -F @ {'print $1'})
  sshDir=${users_mount}/$login/.ssh
  [ ! -d $sshDir ] && adduser --home ${users_mount}/$login $login && mkdir -p $sshDir && chown $login:$login $sshDir && chmod 700 $sshDir
  arn=$(echo "$usersJson" | jq -r ".Users[$idx].Arn")
  if [ "allowed" == "$(aws iam simulate-principal-policy --policy-source-arn $arn --action-names iam:CreateUser | jq -r '.EvaluationResults[0].EvalDecision')" ]; then
    logger -t sync_keys "User is an admin and will be granted sudo access; login=$login"
    echo "$login ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/iam
  fi
  authHosts=$sshDir/authorized_keys
  echo '# DO NOT MODIFY THIS FILE - IT IS AUTO-GENERATED DAILY' > $authHosts
  chown $login:$login $authHosts
  chmod 600 $authHosts
  for sshKeyId in $(aws iam list-ssh-public-keys --user-name "$userName" | jq -r '.SSHPublicKeys[].SSHPublicKeyId'); do
    keyData=$(aws iam get-ssh-public-key --user-name "$userName" --ssh-public-key-id $sshKeyId --encoding SSH)
    if [ "Active" == "$(echo $keyData | jq -r '.SSHPublicKey.Status')" ]; then
      logger -t sync_keys "Syncing SSH public key; login=$login"
      echo $keyData | jq -r '.SSHPublicKey.SSHPublicKeyBody' >> $authHosts
    fi
  done
  if [ -f ${users_mount}/$login/.jumppasswd ]; then
    logger -t sync_keys "Synchronizing jumppasswd; login=$login"
    echo "$login:$(head -n 1 ${users_mount}/$login/.jumppasswd | sed -e 's/^.*://')" >> ${users_mount}/etc/jumppasswd.tmp
  fi
  idx=$((idx+1))
done
cat ${users_mount}/etc/jumppasswd.tmp > ${users_mount}/etc/jumppasswd
chmod 640 ${users_mount}/etc/jumppasswd
getent group jumppasswd || groupadd jumppasswd
chgrp jumppasswd ${users_mount}/etc/jumppasswd
rm -f ${users_mount}/etc/jumppasswd.tmp
logger -t sync_keys "Finished user synchronization"
EOF
chmod 700 /etc/cron.hourly/sync_keys

# Automatically recycle this host daily. Note that this host is using GMT timezone.
crontab << \RECYCLEEOF
00 09 * * * /sbin/shutdown -P +5 "This jump host is being automatically recycled; self-destruct sequence is currently in progress."
RECYCLEEOF

# Reposition security files onto users share for re-use across similar hosts.
# Create a script that will do this, so that other hosts can re-use the script.
mkdir -p ${users_mount}/etc/sudoers.d
mkdir -p ${users_mount}/bootstrap
if [ ! -f ${users_mount}/etc/passwd ]; then
  mv /etc/passwd /etc/group /etc/gshadow /etc/shadow ${users_mount}/etc/
  chmod 600 ${users_mount}/etc/shadow ${users_mount}/etc/gshadow
fi
if [ ! -f ${users_mount}/etc/sudoers.d/iam ]; then
  touch ${users_mount}/etc/sudoers.d/iam
  chmod 600 ${users_mount}/etc/sudoers.d/iam
fi

# Save context name in EFS (to reference on other hosts)
if [ ! -f ${users_mount}/etc/context ]; then
  echo "${context}" > ${users_mount}/etc/context
fi

cat << \EOF > ${users_mount}/bootstrap/runOnNewHost.sh
instance_role=$1
[ "$instance_role" == "" ] && instance_role=unknown
echo "$instance_role" > /etc/instance_role

for cmd in useradd userdel groupadd groupdel groupmod usermod
do 
  cat << SECURESCRIPTEOF > ${users_mount}/bootstrap/$cmd
#!/bin/bash
for f in passwd group gshadow shadow
do
  unlink /etc/\$f
  cp ${users_mount}/etc/\$f /etc/
done
/usr/sbin/$cmd.orig "\$@"
for f in passwd group gshadow shadow
do
  mv /etc/\$f ${users_mount}/etc/
  ln -sf ${users_mount}/etc/\$f /etc/\$f
done
SECURESCRIPTEOF
  chmod 700 ${users_mount}/bootstrap/$cmd
  mv /usr/sbin/$cmd /usr/sbin/$cmd.orig
  ln -sf ${users_mount}/bootstrap/$cmd /usr/sbin/$cmd
  logger -t runOnNewHost "Created security stub script for $cmd"
done

# Use supplied context name, or default to foundry context if not supplied
if [[ -n $2 ]]; then
  context=$2
else
  context="${context}"
fi
echo "$context" > /etc/context

ln -sf ${users_mount}/etc/passwd /etc/passwd
ln -sf ${users_mount}/etc/group /etc/group
ln -sf ${users_mount}/etc/gshadow /etc/gshadow
ln -sf ${users_mount}/etc/shadow /etc/shadow
ln -sf ${users_mount}/etc/sudoers.d/iam /etc/sudoers.d/iam
logger -t runOnNewHost "Repositioned security files to users share"
instance_id=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
mkdir -p /etc/awslogs/config
cat > /etc/awslogs/awslogs.conf <<EOFLOG
[general]
state_file=/etc/awslogs/${log_group}.state
use_gzip_http_content_encoding=true
EOFLOG
cat > /etc/awslogs/config/foundry.conf <<EOFLOG
[cloud-init]
log_group_name=${log_group}
log_stream_name=$instance_role-$instance_id-cloud-init-output
datetime_format=%d %b %Y %H:%M:%S
file=/var/log/cloud-init-output.log

[sshd]
log_group_name=${log_group}
log_stream_name=$instance_role-$instance_id-secure
datetime_format=%b %d %H:%M:%S
file=/var/log/secure

[messages]
log_group_name=${log_group}
log_stream_name=$instance_role-$instance_id-messages
datetime_format=%b %d %H:%M:%S
file=/var/log/messages
EOFLOG
service awslogs start
chkconfig awslogs on
logger -t runOnNewHost "Configured CloudWatch Log Group"

# Set default prompt to include context and instance role
if [[ ! -f /etc/profile.d/foundry-prompt.sh ]]; then
  ln -s ${users_mount}/etc/profile.d/foundry-prompt.sh /etc/profile.d/foundry-prompt.sh
fi
EOF
chmod 700 ${users_mount}/bootstrap/runOnNewHost.sh

# Set default prompt to include context name and instance role
if [[ ! -f ${users_mount}/etc/foundry-prompt.sh ]]; then
  mkdir -p ${users_mount}/etc/profile.d
  cat > ${users_mount}/etc/profile.d/foundry-prompt.sh <<EOF
if [ "\$PS1" ]; then
  if [[ -r /etc/context ]]; then
    CONTEXT=\$(cat /etc/context)
  fi
  if [[ -r /etc/instance_role ]]; then
    ROLE="\$(cat /etc/instance_role) "
  fi

  PS1="[\u@\h \$CONTEXT \$ROLE\W]\\$ "
fi
EOF
fi
rm -f /etc/profile.d/foundry-prompt.sh
chmod +x ${users_mount}/etc/profile.d/foundry-prompt.sh

# Create executeable script for users to set a password for use by internal systems, such as the proxy
cat > /usr/local/bin/jumppasswd << \EOFPASSWD
htpasswd -c ~/.jumppasswd $USER
chmod 600 ~/.jumppasswd
EOFPASSWD
chmod a+x /usr/local/bin/jumppasswd

cat > /usr/local/bin/jumphelp << \EOFHELP
echo -e "Welcome to the Jump host help!\n"
echo -e "Jump host common commands include the following:"
echo -e "  jumphelp   - display this help message"
echo -e "  jumppasswd - create or change your password used for alternative authentication,"
echo -e "               such as with the reverse proxy for command line access to Ivy, etc."
EOFHELP
chmod a+x /usr/local/bin/jumphelp
# JUMP END - End jump host specifics.

# All hosts should execute the following script upon instance creation.
${users_mount}/bootstrap/runOnNewHost.sh "jump" "${context}"

# Force key sync execution immediately. Only used on jump host.
/etc/cron.hourly/sync_keys
