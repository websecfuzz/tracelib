#!/bin/sh

set -u

cd /usr/src/redmine

for i in $(seq 1 30); do
    if bundle exec rails runner -e production \
        'exit (User.where(login: "admin").exists? ? 0 : 1)' >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

bundle exec rails runner -e production "
  u = User.find_by(login: 'admin')
  if u
    u.password = '${REDMINE_ADMIN_PASSWORD:-admin123}'
    u.password_confirmation = '${REDMINE_ADMIN_PASSWORD:-admin123}'
    u.must_change_passwd = false
    u.save!
    puts \"admin password set; must_change_passwd=#{u.must_change_passwd}\"
  else
    puts 'admin user not found yet'
  end
" 2>&1 | sed 's/^/[redmine-init] /'
