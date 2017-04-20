#!/bin/bash
set -eux

config_organization_name=Example
config_fqdn=$(hostname --fqdn)
config_domain=$(hostname --domain)
config_domain_dc="dc=$(echo $config_domain | sed 's/\./,dc=/g')"
config_admin_dn="cn=admin,$config_domain_dc"
config_admin_password=password

echo "127.0.0.1 $config_fqdn" >>/etc/hosts

apt-get install -y --no-install-recommends vim
cat >/etc/vim/vimrc.local <<'EOF'
syntax on
set background=dark
set esckeys
set ruler
set laststatus=2
set nobackup
autocmd BufNewFile,BufRead Vagrantfile set ft=ruby
EOF

# these anwsers were obtained (after installing slapd) with:
#
#   #sudo debconf-show slapd
#   sudo apt-get install debconf-utils
#   # this way you can see the comments:
#   sudo debconf-get-selections
#   # this way you can just see the values needed for debconf-set-selections:
#   sudo debconf-get-selections | grep -E '^slapd\s+' | sort
debconf-set-selections <<EOF
slapd slapd/password1 password $config_admin_password
slapd slapd/password2 password $config_admin_password
slapd slapd/domain string $config_domain
slapd shared/organization string $config_organization_name
EOF

apt-get install -y --no-install-recommends slapd ldap-utils

#
# install memberof overlay so member and memberof attributes match.
# based on: https://technicalnotes.wordpress.com/2014/04/19/openldap-setup-with-memberof-overlay/
#

sudo ldapadd -Q -Y EXTERNAL -H ldapi:/// <<EOF
dn: cn=module{1},cn=config
cn: module{1}
objectClass: olcModuleList
olcModuleLoad: memberof
olcModulePath: /usr/lib/ldap

dn: olcOverlay={0}memberof,olcDatabase={1}mdb,cn=config
objectClass: olcConfig
objectClass: olcMemberOf
objectClass: olcOverlayConfig
objectClass: top
olcOverlay: memberof
olcMemberOfDangling: ignore
olcMemberOfRefInt: TRUE
olcMemberOfGroupOC: groupOfNames
olcMemberOfMemberAD: member
olcMemberOfMemberOfAD: memberOf
EOF

sudo ldapmodify -Q -Y EXTERNAL -H ldapi:/// <<EOF
dn: cn=module{1},cn=config
add: olcmoduleload
olcmoduleload: refint
EOF

sudo ldapadd -Q -Y EXTERNAL -H ldapi:/// <<EOF
dn: olcOverlay={1}refint,olcDatabase={1}mdb,cn=config
objectClass: olcConfig
objectClass: olcOverlayConfig
objectClass: olcRefintConfig
objectClass: top
olcOverlay: {1}refint
olcRefintAttribute: memberof member manager owner
EOF


# create the people container.
# NB the `cn=admin,$config_domain_dc` user was automatically created
#    when the slapd package was installed.
ldapadd -D $config_admin_dn -w $config_admin_password <<EOF
dn: ou=people,$config_domain_dc
objectClass: organizationalUnit
ou: people
EOF

# add people.
function add_person {
    local n=$1; shift
    local name=$1; shift
    local groupNum=2
    [[ $((n%2)) -eq 0 ]] && groupNum=1
    ldapadd -D $config_admin_dn -w $config_admin_password <<EOF
dn: uid=$name,ou=people,$config_domain_dc
objectClass: inetOrgPerson
userPassword: $(slappasswd -s password)
uid: $name
mail: $name@$config_domain
cn: $name doe
givenName: $name
sn: doe
telephoneNumber: +1 888 555 000$((n+1))
labeledURI: http://example.com/~$name Personal Home Page
jpegPhoto::$(base64 -w 66 /vagrant/avatars/avatar-$n.jpg | sed 's,^, ,g')
EOF
}

people=(alice bob carol dave eve frank grace henry)
for n in "${!people[@]}"; do
    add_person $n "${people[$n]}"
done

# create the group container and 2 groups
# Notice that only dave and eve are in both groups
ldapadd -D $config_admin_dn -w $config_admin_password <<EOF
dn: ou=groups,$config_domain_dc
objectClass: organizationalUnit
ou: groups

dn: cn=group1,ou=groups,$config_domain_dc
objectClass: top
objectClass: groupOfNames
member: uid=alice,ou=people,$config_domain_dc
member: uid=bob,ou=people,$config_domain_dc
member: uid=carol,ou=people,$config_domain_dc
member: uid=dave,ou=people,$config_domain_dc
member: uid=eve,ou=people,$config_domain_dc

dn: cn=group2,ou=groups,$config_domain_dc
objectClass: top
objectClass: groupOfNames
member: uid=dave,ou=people,$config_domain_dc
member: uid=eve,ou=people,$config_domain_dc
member: uid=frank,ou=people,$config_domain_dc
member: uid=grace,ou=people,$config_domain_dc
member: uid=henry,ou=people,$config_domain_dc
EOF

# show the configuration tree.
ldapsearch -Q -LLL -Y EXTERNAL -H ldapi:/// -b cn=config dn | grep -v '^$'

# show the data tree.
ldapsearch -x -LLL -b $config_domain_dc dn | grep -v '^$'

# search for people and print some of their attributes.
ldapsearch -x -LLL -b $config_domain_dc '(objectClass=person)' cn mail
