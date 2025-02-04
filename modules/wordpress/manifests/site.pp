# @summary installs and manages a wordpress blog
# @param $host main host name of this blog
# @param $certificate lets encrypt certificate name
# @param $db_password_seed seed to use to generate a database password
define wordpress::site (
  Stdlib::Fqdn              $host,
  Wordpress::Path           $path,
  String[1]                 $site_name,
  Optional[String[1]]       $version,
  String[1]                 $certificate,
  String[1]                 $db_password_seed,
  Stdlib::Email             $admin_email,
  String[1]                 $admin_password,
  Stdlib::Unixpath          $base_path,
  String[1]                 $active_theme,
  Array[Stdlib::Unixpath]   $config_files        = [],
  Array[Wordpress::Theme]   $themes              = [],
  Array[Wordpress::Option]  $options             = [],
  Array[Wordpress::User]    $users               = [],
  Array[Wordpress::Plugin]  $plugins             = [],
  Array[Wordpress::Sidebar] $sidebars            = [],
  String[1]                 $permalink_structure = '/%year%/%monthnum%/%day%/%postname%/',
  Boolean                   $gilded_wordpress    = false,
  Stdlib::Unixpath          $webroot             = $base_path,
) {
  mariadb::database { "wordpress_${title}": }

  $db_user_password = jqlib::autogen_password($title, $db_password_seed)

  mariadb::user { "wordpress_${title}":
    host => '127.0.0.1',
    auth => { password => $db_user_password },
  }

  mariadb::grant { "wordpress_${title}":
    user_name => "wordpress_${title}",
    user_host => '127.0.0.1',
    database  => "wordpress_${title}",
    grants    => { all => true },
  }

  $version_arg = ($version != undef).bool2str("--version=${version}", '')
  exec { "wp-download-${title}":
    command   => "/usr/local/bin/wp core download --path=${base_path} ${version_arg}",
    creates   => $base_path,
    user      => 'www-data',
    require   => File['/usr/local/bin/wp'],
    logoutput => true,
  }

  if $version {
    exec { "wp-update-${title}":
      command   => "/usr/local/bin/wp core update --path=${base_path} --version=${version}",
      unless    => "test \"$(wp --path=${base_path} core version)\" = \"${version}\"",
      user      => 'www-data',
      logoutput => true,
      # for the unless test command to work
      provider  => 'shell',
      notify    => Exec["wp-update-db-${title}"],
    }

    exec { "wp-update-db-${title}":
      command     => "/usr/local/bin/wp core update-db --path=${base_path}",
      user        => 'www-data',
      logoutput   => true,
      refreshonly => true,
    }
  }

  $themes.each |Wordpress::Theme $theme| {
    $theme_name = $theme['name']
    file { "${base_path}/wp-content/themes/${theme_name}":
      ensure => link,
      target => $theme['path'],
    }
  }

  exec { "wp-create-config-${title}":
    command   => "/usr/local/bin/wp config create --path=${base_path} --dbname=wordpress_${title} --dbuser=wordpress_${title} --dbhost=127.0.0.1 --dbpass=\"${db_user_password}\"",
    creates   => "${base_path}/wp-config.php",
    user      => 'www-data',
    require   => [
      Mariadb::Database["wordpress_${title}"],
      Mariadb::User["wordpress_${title}"],
      Mariadb::Grant["wordpress_${title}"],
      Exec["wp-download-${title}"]
    ],
    notify    => Exec["wp-install-${title}"],
    logoutput => true,
  }

  file { "${base_path}/jquery-config-base.php":
    ensure  => file,
    content => template('wordpress/site/jquery-config-base.php.erb'),
    require => Exec["wp-create-config-${title}"],
  }

  ($config_files + ["${base_path}/jquery-config-base.php"]).each |Stdlib::Unixpath $path| {
    file_line { "wp-config-file-${title}-${path}":
      ensure  => present,
      path    => "${base_path}/wp-config.php",
      line    => "require '${path}';",
      after   => 'Add any custom values between',
      require => [Exec["wp-create-config-${title}"], File[$path]],
      before  => Exec["wp-install-${title}"],
    }
  }

  exec { "wp-install-${title}":
    command     => "/usr/local/bin/wp core install --path=${base_path} --url=https://${host}${path} --title=\"${site_name}\" --admin_user=admin --admin_email=${admin_email} --admin_password=\"${admin_password}\" --skip-email",
    user        => 'www-data',
    logoutput   => true,
    refreshonly => true,
  }

  exec { "wp-theme-${title}":
    command   => "/usr/local/bin/wp --path=${base_path} theme activate ${active_theme}",
    unless    => "/usr/local/bin/wp --path=${base_path} theme is-active ${active_theme}",
    user      => 'www-data',
    logoutput => true,
    require   => Exec["wp-install-${title}"],
  }

  exec { "wp-permalink-structure-${title}":
    command   => "/usr/local/bin/wp --path=${base_path} rewrite structure \"${permalink_structure}\"",
    unless    => "test \"$(wp --path=${base_path} option get permalink_structure)\" = \"${permalink_structure}\"",
    user      => 'www-data',
    logoutput => true,
    # for the unless test command to work
    provider  => 'shell',
    require   => Exec["wp-install-${title}"],
  }

  # Delete the "Welcome to WordPress!" post and the assosiated comment
  exec { "wp-delete-sample-post-${title}":
    command   => "/usr/local/bin/wp --path=${base_path} post delete 1 --force",
    onlyif    => "/usr/local/bin/wp --path=${base_path} post get 1",
    user      => 'www-data',
    logoutput => true,
    require   => Exec["wp-install-${title}"],
  }

  $options.each |Wordpress::Option $option| {
    $option_name = $option['name']
    $option_value = $option['value']
    exec { "wp-option-${title}-${option_name}":
      command   => "/usr/local/bin/wp --path=${base_path} option set ${option_name} \"${option_value}\"",
      unless    => "test \"$(wp --path=${base_path} option get ${option_name})\" = \"${option_value}\"",
      user      => 'www-data',
      logoutput => true,
      # for the unless test command to work
      provider  => 'shell',
      require   => Exec["wp-install-${title}"],
    }
  }

  $users.each |Wordpress::User $user| {
    $username = $user['username']
    $password = $user['password']
    $email = $user['email']
    $role = $user['role']
    exec { "wp-user-${title}-${username}":
      command   => "/usr/local/bin/wp --path=${base_path} user create ${username} ${email} --role=${role} --user_pass=\"${password}\"",
      unless    => "/usr/local/bin/wp --path=${base_path} user get ${username}",
      user      => 'www-data',
      logoutput => true,
      require   => Exec["wp-install-${title}"],
    }
  }

  $plugins.each |Wordpress::Plugin $plugin| {
    $plugin_name = $plugin['name']
    $extension = $plugin['single_file'].bool2str('.php', '')
    file { "${base_path}/wp-content/plugins/${plugin_name}${extension}":
      ensure => link,
      target => $plugin['path'],
    }

    exec { "wp-plugin-${title}-${plugin_name}":
      command   => "/usr/local/bin/wp --path=${base_path} plugin activate ${plugin_name}",
      unless    => "/usr/local/bin/wp --path=${base_path} plugin is-active ${plugin_name}",
      user      => 'www-data',
      logoutput => true,
      require   => Exec["wp-install-${title}"],
    }
  }

  $sidebars.each |Wordpress::Sidebar $sidebar| {
    $slot = $sidebar['slot']
    if $sidebar['ensure'] != 'absent' {
      fail("sidebar ${slot}: invalid ensure value")
    }

    exec { "wp-sidebar-${title}-${slot}-clear":
      command   => "/usr/local/bin/wp --path=${base_path} widget reset ${slot}",
      unless    => "test \"$(wp --path=${base_path} --format=json widget list ${slot})\" = \"[]\"",
      user      => 'www-data',
      logoutput => true,
      # for the unless test command to work
      provider  => 'shell',
      require   => Exec["wp-install-${title}"],
    }
  }

  $php_fpm_version = $::php::fpm::version
  if $path == '/' {
    $tls_config = nginx::tls_config()
    nginx::site { "wordpress-${title}":
      content => template('wordpress/site/site.nginx.erb'),
    }

    file { "/etc/nginx/wordpress-subsites/${host}.d":
      ensure  => directory,
      owner   => 'root',
      group   => 'root',
      recurse => true,
      purge   => true,
      force   => true,
      notify  => Exec['nginx-reload'],
    }
  } else {
    file { "/etc/nginx/wordpress-subsites/${host}.d/${regsubst($title, '[\W_]', '-', 'G')}.conf":
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      content => template('wordpress/site/subsite.nginx.erb'),
      notify  => Exec['nginx-reload'],
    }
  }
}
