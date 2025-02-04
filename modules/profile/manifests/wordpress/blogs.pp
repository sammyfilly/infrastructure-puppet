# @summary various blog sites
class profile::wordpress::blogs (
  Profile::Wordpress::Blogs::Sites $sites             = lookup('profile::wordpress::blogs::sites'),
  Optional[String[1]]              $wordpress_version = lookup('profile::wordpress::blogs::wordpress_version'),
  String[1]                        $db_password_seed  = lookup('profile::wordpress::blogs::db_password_seed'),
  Stdlib::Email                    $admin_email       = lookup('profile::wordpress::blogs::admin_email'),
  String[1]                        $admin_password    = lookup('profile::wordpress::blogs::admin_password'),
) {
  include profile::wordpress::base

  git::clone { 'blog.jquery.com-theme':
    path   => '/srv/wordpress/blog.jquery.com-theme',
    remote => 'https://github.com/jquery/blog.jquery.com-theme',
    branch => 'main',
    owner  => 'www-data',
    group  => 'www-data',
  }

  $sites.each |String[1] $name, Hash $site| {
    $active_theme = $site['active_theme']
    wordpress::site { $name:
      *                => $site,
      path             => '/',
      version          => $wordpress_version,
      db_password_seed => $db_password_seed,
      admin_email      => $admin_email,
      admin_password   => $admin_password,
      themes           => [
        { name => 'jquery',      path => '/srv/wordpress/blog.jquery.com-theme/jquery', },
        { name => $active_theme, path => "/srv/wordpress/blog.jquery.com-theme/${active_theme}", },
      ],
      options          => [],
      base_path        => "/srv/wordpress/sites/${name}",
    }
  }

  tarsnap::backup { 'wordpress':
    paths => $sites.keys.map |String[1] $site| { "/srv/wordpress/sites/${site}/wp-content/uploads/" },
  }

  nftables::allow { 'wordpress-blogs-https':
    proto => 'tcp',
    dport => 443,
  }

  class { 'tarsnap::mariadb':
    database_pattern => 'wordpress\\_%',
  }
}
