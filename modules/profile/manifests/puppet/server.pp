# @summary provisions a puppet server
class profile::puppet::server (
  String[1]     $java_memory            = lookup('profile::puppet::server::java_memory', {default_value => '1g'}),
  String[1]     $g10k_branch_filter     = lookup('profile::puppet::server::g10k_branch_filter'),
  String[1]     $nginx_certificate_name = lookup('profile::puppet::server::nginx_certificate_name'),
  Stdlib::Email $tarsnap_account_email  = lookup('profile::puppet::server::tarsnap_account_email'),
) {
  include profile::puppet::common

  package { [
    'puppetserver',
    'puppetdb-termini',
    'g10k',

    # for the htpasswd tool
    'apache2-utils',
  ]:
    ensure => installed,
  }

  systemd::sysuser { 'gitpuppet':
    source => 'puppet:///modules/profile/puppet/server/sysusers.conf',
  }

  exec { 'remove-old-code-dir':
    command => '/usr/bin/mv /etc/puppetlabs/code /etc/puppetlabs/code-old',
    creates => '/etc/puppetlabs/code-old',
  }

  file { '/etc/puppetlabs/code':
    ensure  => directory,
    owner   => 'gitpuppet',
    group   => 'gitpuppet',
    require => Exec['remove-old-code-dir'],
  }

  file { [
    '/srv/git',
    '/srv/git/puppet',
  ]:
    ensure => directory,
  }

  $g10k_deploy_base_path = '/etc/puppetlabs/code/environments'
  $private_repo_dir = '/srv/git/puppet/private'

  file { '/etc/puppetlabs/g10k.yaml':
    ensure  => file,
    content => template('profile/puppet/server/g10k.yaml.erb'),
    owner   => 'root',
    group   => 'root',
    mode    => '0444',
    notify  => Exec['g10k'],
  }

  exec { 'g10k':
    command     => '/usr/bin/g10k -config /etc/puppetlabs/g10k.yaml',
    user        => 'gitpuppet',
    refreshonly => true,
    logoutput   => true,
    require     => File['/etc/puppetlabs/code'],
  }

  file { '/usr/local/bin/puppet-merge':
    ensure => file,
    source => 'puppet:///modules/profile/puppet/server/puppet-merge.sh',
    owner  => 'root',
    group  => 'gitpuppet',
    mode   => '0554',
  }

  file { $private_repo_dir:
    ensure => directory,
    owner  => 'gitpuppet',
    group  => 'gitpuppet',
    mode   => '2775',
  }
  exec { 'git-init-puppet-private':
    command => "/usr/bin/git -c core.sharedRepository=group init ${private_repo_dir}",
    creates => "${private_repo_dir}/.git",
    user    => 'gitpuppet',
    group   => 'gitpuppet',
    umask   => '002',
  }

  file { [
    "${private_repo_dir}/hieradata/",
    "${private_repo_dir}/files/",
  ]:
    ensure  => directory,
    owner   => 'gitpuppet',
    group   => 'gitpuppet',
    mode    => '2775',
    require => Exec['git-init-puppet-private'],
  }

  file { '/etc/puppetlabs/hieradata':
    ensure  => absent,
    recurse => true,
    force   => true,
    purge   => true,
  }

  systemd::tmpfile { 'g10k-cache':
    content => 'd /tmp/g10k 2775 gitpuppet gitpuppet',
  }

  concat::fragment { 'puppet-config-server':
    target  => $::profile::puppet::common::config_file,
    order   => '20',
    content => template('profile/puppet/server/puppet.conf.erb'),
  }

  Concat::Fragment <| target == $::profile::puppet::common::config_file |> ~> Service['puppetserver']
  Concat[$::profile::puppet::common::config_file] ~> Service['puppetserver']

  ['puppetserver.conf'].each |String $file| {
    file { "/etc/puppetlabs/puppetserver/conf.d/${file}":
      ensure  => file,
      mode    => '0440',
      group   => 'puppet',
      content => template("profile/puppet/server/config/${file}.erb"),
      notify  => Service['puppetserver'],
    }
  }

  file { '/etc/puppetlabs/puppet/routes.yaml':
    ensure  => file,
    mode    => '0444',
    content => template('profile/puppet/server/routes.yaml.erb'),
    notify  => Service['puppetserver'],
  }

  file { '/etc/puppetlabs/puppet/puppetdb.conf':
    ensure  => file,
    mode    => '0444',
    content => template('profile/puppet/server/puppetdb.conf.erb'),
    notify  => Service['puppetserver'],
  }

  file { '/etc/default/puppetserver':
    ensure  => file,
    mode    => '0444',
    content => template('profile/puppet/server/default.erb'),
    notify  => Service['puppetserver'],
  }

  service { 'puppetserver':
    ensure => running,
    enable => true,
  }

  nftables::allow { 'puppetserver':
    proto => 'tcp',
    dport => 8140,
  }

  notifier::run_command { 'puppet-public':
    github_repository => 'jquery/infrastructure-puppet',
    listen_for        => [{ branch => 'staging' }, { branch => 'production' }],
    source            => 'puppet:///modules/profile/puppet/server/puppet-merge.sh',
  }

  sudo::rule { 'notifier-g10k':
    target     => 'notifier',
    privileges => [
      'ALL = (gitpuppet) NOPASSWD: /usr/bin/g10k -config /etc/puppetlabs/g10k.yaml',
    ],
  }

  git::config { '/etc/gitconfig':
    settings => {
      'safe' => {
        'directory' => $private_repo_dir,
      },
    },
  }

  class { 'tarsnap::keymgmt':
    base_path     => "${private_repo_dir}/files/tarsnap-keys",
    account_email => $tarsnap_account_email,
    user          => 'gitpuppet',
    group         => 'gitpuppet',
  }

  tarsnap::backup { 'puppet-private':
    paths => [$private_repo_dir],
  }

  include profile::ssh::ca

  # Expose SSH keys so users can verify them
  file { '/srv/www':
    ensure => directory,
  }

  $ca_data = jqlib::secret('ssh_ca/ca.pub')
  $keys = jqlib::puppetdb_query('resources[certname, parameters] { type = "Sshkey" and exported = true }').map |$key| {
    $names = [$key['certname']] + $key['parameters']['host_aliases']
    "${names.sort.join(',')} ${key['parameters']['type']} ${key['parameters']['key']}"
  }.sort

  file { '/srv/www/known_hosts':
    ensure    => file,
    content   => template('profile/puppet/server/web/known_hosts.erb'),
    show_diff => false,
  }

  $tls_config = nginx::tls_config()
  nginx::site { 'puppet-metadata':
    content => template('profile/puppet/server/web/site.nginx.erb'),
    require => Letsencrypt::Certificate[$nginx_certificate_name],
  }

  nftables::allow { 'puppet-metadata':
    proto => 'tcp',
    dport => 443,
  }
}
