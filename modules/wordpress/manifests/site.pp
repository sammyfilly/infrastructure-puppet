# @summary installs and manages a wordpress blog
# @param $host main host name of this blog
# @param $certificate lets encrypt certificate name
# @param $db_password_seed seed to use to generate a database password
define wordpress::site (
  Stdlib::Fqdn            $host,
  String[1]               $site_name,
  String[1]               $certificate,
  String[1]               $db_password_seed,
  Stdlib::Email           $admin_email,
  String[1]               $admin_password,
  Stdlib::Unixpath        $base_path,
  Array[Wordpress::Theme] $themes,
  String[1]               $active_theme,
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

  exec { "wp-download-${title}":
    command   => "/usr/local/bin/wp core download --path=${base_path}",
    creates   => $base_path,
    user      => 'www-data',
    require   => File['/usr/local/bin/wp'],
    logoutput => true,
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

  exec { "wp-install-${title}":
    command     => "/usr/local/bin/wp core install --path=${base_path} --url=https://${host} --title=\"${site_name}\" --admin_user=admin --admin_email=${admin_email} --admin_password=\"${admin_password}\" --skip-email",
    user        => 'www-data',
    logoutput   => true,
    refreshonly => true,
  }

  exec { "wp-theme-${title}":
    command   => "/usr/local/bin/wp --path=${base_path} theme activate ${active_theme}",
    unless    => "/usr/local/bin/wp --path=${base_path} theme is-active ${active_theme}",
    logoutput => true,
    require   => Exec["wp-install-${title}"],
  }

  $tls_config = nginx::tls_config()
  $php_fpm_version = $::php::fpm::version
  nginx::site { "wordpress-${title}":
    content => template('wordpress/site/site.nginx.erb'),
  }
}
