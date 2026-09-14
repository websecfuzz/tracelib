#!/bin/bash
set -u

cd /app
export HOME=/app

USERNAME="${SEED_USERNAME:-admin}"
PASSWORD="${SEED_PASSWORD:-admin123}"
EMAIL="${SEED_EMAIL:-admin@example.com}"

for i in $(seq 1 60); do
    if bundle exec rails runner -e "${RAILS_ENV:-production}" \
        'exit(ActiveRecord::Base.connection.table_exists?(:users) ? 0 : 1)' >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

USERNAME="$USERNAME" PASSWORD="$PASSWORD" EMAIL="$EMAIL" \
bundle exec rails runner -e "${RAILS_ENV:-production}" '
  username = ENV["USERNAME"]
  password = ENV["PASSWORD"]
  email    = ENV["EMAIL"]

  user = User.find_by(username: username) || User.find_by(email: email) || User.new
  user.username = username
  user.email = email
  user.password = password
  user.password_confirmation = password
  user.admin = true
  user.invitation_code = User::INVITATION_CODES.first if user.invitation_code.blank?
  user.skip_confirmation! if user.respond_to?(:skip_confirmation!)
  user.save!(validate: false) unless user.save
  puts "admin user ready: #{user.username} (admin=#{user.admin?})"
' 2>&1 | sed 's/^/[huginn-init] /'
