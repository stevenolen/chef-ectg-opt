#
# Cookbook Name:: mwser-opt
# Recipe:: default
#
# Copyright (C) 2015 UC Regents
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# require chef-vault
chef_gem 'chef-vault'
require 'chef-vault'

# some basic package deps. only tested on rhel family.
package 'git'

case node['fqdn']
when 'onlinepoll.ucla.edu'
  fqdn = 'onlinepoll.ucla.edu'
  app_name = 'prod'
  app_revision = '2.4.6'
  rails_env = 'production'
  port = 3000
  bridge_enabled = true
  shib_client = 'opt'
when 'staging.m.ucla.edu' # staging.onlinepoll.ucla.edu
  fqdn = 'staging.onlinepoll.ucla.edu'
  app_name = 'staging'
  app_revision = 'master'
  rails_env = 'staging'
  port = 3002
  bridge_enabled = false
  shib_client = 'staging_opt'
when 'test.onlinepoll.ucla.edu' # staging.onlinepoll.ucla.edu
  fqdn = 'test.onlinepoll.ucla.edu'
  app_name = 'test'
  app_revision = 'master'
  rails_env = 'staging'
  repo = 'git@github.com:mutaron/opt'
  port = 3002
  bridge_enabled = false
  shib_client = 'test_opt'
end

subdomains = ['generic'] # removed ucr

# install mysql
db_root_obj = ChefVault::Item.load("passwords", "db_root")
db_root = db_root_obj[node['fqdn']]
db_opt_obj = ChefVault::Item.load("passwords", "opt")
db_opt = db_opt_obj[fqdn]
mysql_service 'default' do
  port '3306'
  version '5.6'
  initial_root_password db_root
  action [:create, :start]
end

mysql_connection = {
  :host => '127.0.0.1',
  :port => 3306,
  :username => 'root',
  :password => db_root
}

# set up opt db
mysql2_chef_gem 'default'
mysql_database 'opt' do
  connection mysql_connection
  action :create
end
mysql_database_user 'opt' do
  connection mysql_connection
  password db_opt
  database_name 'opt'
  action [:create,:grant]
end

# install nginx
node.set['nginx']['default_site_enabled'] = false
node.set['nginx']['install_method'] = 'package'
include_recipe 'nginx::repo'
include_recipe 'nginx'

directory '/etc/ssl/private' do
  recursive true
end

# add SSL certs to box
ssl_key_cert = ChefVault::Item.load('ssl', fqdn) # gets ssl cert from chef-vault
file "/etc/ssl/certs/#{fqdn}.crt" do
  owner 'root'
  group 'root'
  mode '0777'
  content ssl_key_cert['cert']
  notifies :reload, 'service[nginx]', :delayed
end
file "/etc/ssl/private/#{fqdn}.key" do
  owner 'root'
  group 'root'
  mode '0600'
  content ssl_key_cert['key']
  notifies :reload, 'service[nginx]', :delayed
end

# nginx conf
template '/etc/nginx/sites-available/opt' do
  source 'opt.conf.erb'
  mode '0775'
  action :create
  variables(
    app_name: app_name,
    fqdn: fqdn,
    port: port,
    path: '/var/www/', # not used.
    bridge_enabled: bridge_enabled
  )
  notifies :reload, 'service[nginx]', :delayed
end
nginx_site 'opt' do
  action :enable
end

# nginx and SSL conf for custom subdomain hosts
subdomains.each do |subdomain|
  template "/etc/nginx/sites-available/opt-#{subdomain}"  do
    source 'opt.conf.erb'
    mode '0775'
    action :create
    variables(
        app_name: "#{app_name}_#{subdomain}",
        fqdn: "#{subdomain}.#{fqdn}",
        port: port,
        path: '/var/www/', # not used.
        bridge_enabled: false
    )
    notifies :reload, 'service[nginx]', :delayed
  end
  ssl_key_cert = ChefVault::Item.load('ssl', "#{subdomain}.#{fqdn}") # gets ssl cert from chef-vault
  file "/etc/ssl/certs/#{subdomain}.#{fqdn}.crt" do
    owner 'root'
    group 'root'
    mode '0777'
    content ssl_key_cert['cert']
    notifies :reload, 'service[nginx]', :delayed
  end
  file "/etc/ssl/private/#{subdomain}.#{fqdn}.key" do
    owner 'root'
    group 'root'
    mode '0600'
    content ssl_key_cert['key']
    notifies :reload, 'service[nginx]', :delayed
  end
  nginx_site "opt-#{subdomain}" do
    action :enable
  end
end

# For using strong DH group to prevent Logjam attack
execute "openssl-dhparam" do
  command "openssl dhparam -out /etc/nginx/dhparams.pem 2048"
  not_if { ::File.exist?('/etc/nginx/dhparams.pem') }
end

#add "ssl_dhparam /etc/nginx/dhparams.pem;" to "/etc/nginx/nginx.conf"
template '/etc/nginx/nginx.conf' do
  source 'opt-nginx.conf.erb'
  mode '0644'
  action :create
  variables(
    fqdn: fqdn,
    path: '/var/www/', # not used.
  )
  notifies :reload, 'service[nginx]', :delayed
end



# install ruby with rbenv, npm, git
node.default['rbenv']['rubies'] = ['2.2.3']
include_recipe 'ruby_build'
include_recipe 'ruby_rbenv::system'
include_recipe 'nodejs::npm'
rbenv_global '2.2.3'
rbenv_gem 'bundle'

opt_deploy_key = ChefVault::Item.load('deploy', 'opt') # gets ssl cert from chef-vault
bridge_secrets = ChefVault::Item.load('secrets', 'oauth2') # gets bridge secret from vault.
esb_secrets = ChefVault::Item.load('secrets', 'esb') # gets ESB secret from vault.
rails_secrets = ChefVault::Item.load('secrets', 'rails_secret_tokens')
recaptcha_secrets = ChefVault::Item.load('recaptcha_secrets', fqdn)
smtp_settings = ChefVault::Item.load('smtp', fqdn)

# set up opt!
opt app_name do
  revision app_revision
  port port
  db_password db_opt
  deploy_path '/var/opt'
  bundler_path '/usr/local/rbenv/shims'
  rails_env rails_env
  deploy_key opt_deploy_key['private']
  shib_client_name shib_client
  shib_secret bridge_secrets[shib_client]
  shib_site 'https://onlinepoll.ucla.edu'
  esb_user esb_secrets["#{app_name}_user"]
  esb_pass esb_secrets["#{app_name}_pass"]
  esb_auth_url esb_secrets["#{app_name}_auth_url"]
  esb_cert esb_secrets["#{app_name}_cert"]
  esb_key esb_secrets["#{app_name}_key"]
  secret rails_secrets[fqdn]
  recaptcha_public_key recaptcha_secrets['public']
  recaptcha_private_key recaptcha_secrets['private']
  smtp_host smtp_settings['host']
  smtp_username smtp_settings['username']
  smtp_password smtp_settings['password']
  # assumes es_host is localhost!
end
