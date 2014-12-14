# == Class: exim4u
#
# Setup exim4u mail system (including mysql, clamav, spampassasin, etc.)
#
# === Parameters
#
# Document parameters here.
#
# [*sample_parameter*]
#   Explanation of what this parameter affects and what it defaults to.
#   e.g. "Specify one or more upstream ntp servers as an array."
#
# === Examples
#
#  class { 'exim4u':
#    servers => [ 'pool.ntp.org', 'ntp.local.company.com' ],
#  }
#
# === Authors
#
# Alexey Lebedeff <binarin@gmail.com>
#
# === Copyright
#
# Copyright 2014 Your name here, unless otherwise noted.
#
class exim4u(
  $mysql_root_password,
  $mysql_exim4u_password,
  $uid,
  $gid,
  $primary_hostname,
  $admin_email,
)
{
  Exec {
    path => '/usr/local/bin:/usr/bin:/bin',
  }

  ensure_packages(["exim4-daemon-heavy"])
  ensure_packages(["subversion", "sqlite3", "spf-tools-perl"])
  ensure_packages(["php5", "php5-mysql", "php-db"])
  ensure_packages(["spamassassin", "razor", "libmail-dkim-perl", "libnet-ident-perl", "libio-socket-ssl-perl"])
  ensure_packages(["build-essential", "cpanminus"])
  ensure_packages(["dovecot-mysql", "dovecot-imapd"])

  # ensure_packages(["clamav", "clamav-daemon"])

  $greylist_file = "/var/spool/exim4/greylist.db"

  vcsrepo { "/usr/local/exim4u/":
    require => Package['subversion'],
    ensure => 'present',
    provider => 'svn',
    source => 'http://exim4u.org/svn/exim4u_src/tags/2.1.1/',
  }

  class { "::mysql::server":
    root_password => $mysql_root_password,
  }

  class { os_user:
    uid => $uid,
    gid => $gid,
  } ->
  file { "/home/exim4u/mail":
    ensure => directory,
    owner => $uid,
    group => $gid,
  }

  $exim4u_mysql_schema = '/usr/local/exim4u/mysql_setup/mysql.sql'
  exec { "localize exim4u mysql dump":
    path => '/usr/local/bin:/usr/bin:/bin',
    unless => "test -f ${exim4u_mysql_schema}.local",
    command => "perl -pE 's/(uid\b.*)CHANGE/\${1}${uid}/; s/(gid\b.*)CHANGE/\${1}${gid}/; s/(IDENTIFIED.*)CHANGE/\${1}${mysql_exim4u_password}/' $exim4u_mysql_schema > $exim4u_mysql_schema.local",
  } ->
  ::mysql::db { "exim4u":
    ensure => 'present',
    user => 'exim4u',
    password => hiera('mail_mysql_exim4u_password'),
    host => 'localhost',
    grant => ['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
    sql => "$exim4u_mysql_schema.local",
    import_timeout => 900,
  }

  file { "/etc/exim":
    ensure => directory,
  }

  file { "/etc/exim/exim.pl":
    ensure => link,
    target => '/usr/local/exim4u/etc/exim/exim.pl',
    require => [Vcsrepo["/usr/local/exim4u/"],
                File["/etc/exim"]],
  }

  service { 'exim4':
    ensure => running,
  }

  $config_templates = ["exim4u_acl_check_dkim.conf.inc",
                       "exim4u_backup_mx_host_names",
                       "exim4u_backup_mx_rl_host_names",
                       "exim4u_global_spam_virus",
                       "exim4u_hostnames+hostIPs",
                       "exim4u_IPblacklist",
                       "exim4u_IPskip_sender_verify",
                       "exim4u_IPwhitelist",
                       "exim4u_local.conf.inc",
                       "exim4u_local_rl.conf.inc",
                       "exim4u_relay_from_hosts",
                       "exim4u_sender_rl_addr",
                       "exim4u_sender_rl_dom",
                       "exim-acl-check-spf.conf.inc",
                       "exim.conf",
                       "exim-greylist.conf.inc",
                       "exim-group-router.conf.inc",
                       "exim-mailinglist-router.conf.inc",
                       "exim-mailinglist-transport.conf.inc"
                       ]

  $config_resources = hash(
    flatten(
      $config_templates.map |$x| {
        [ "/etc/exim/$x", { content => template("exim4u/etc/exim/${x}.erb") } ]
      }
    )
  )
  create_resources("file", $config_resources, {
    ensure => present,
    require => File["/etc/exim"],
    notify => Service['exim4'],
  })
  file { "/etc/exim4/exim4.conf":
    ensure => link,
    target => "/etc/exim/exim.conf",
    require => [File["/etc/exim/exim.conf"], Package["exim4-daemon-heavy"]],
  }

  exec { "sqlite3 ${greylist_file} < /usr/local/exim4u/xtrasw/exim-greylist/mk-greylist-db.sql":
    path => '/usr/local/bin:/usr/bin:/bin',
    unless => "test -f ${greylist_file}",
    require => [Package["exim4-daemon-heavy"], Package["sqlite3"]],
  } ~>
  exec { "chown Debian-exim:Debian-exim ${greylist_file}":
    refreshonly => true,
  }

  file { "/etc/cron.daily/greylist-tidy.sh":
    ensure => present,
    content => template("exim4u/etc/cron.daily/greylist-tidy.sh.erb"),
    mode => '0755',
  }

  service { "spamassassin":
    ensure => running,
    require => Package["spamassassin"],
  }

  exec { "perl -pi -e 's/^ENABLED=0/ENABLED=1/' /etc/default/spamassassin":
    unless => "grep -P '^ENABLED=1' /etc/default/spamassassin",
    notify => Service["spamassassin"],
  }
  exec { "perl -pi -e 's/^CRON=0/CRON=1/' /etc/default/spamassassin":
    unless => "grep -P '^CRON=1' /etc/default/spamassassin",
    notify => Service["spamassassin"],
  }

  exec { "cpanm IP::Country::Fast":
    unless => 'perl -MIP::Country::Fast -e 1',
    require => Package["cpanminus"],
  }
  exec { "cpanm Encode::Detect":
    unless => 'perl -MEncode::Detect -e 1',
    require => Package["cpanminus"],
  }
  exec { "cpanm Digest::SHA1":
    unless => 'perl -MDigest::SHA1 -e 1',
    require => Package["cpanminus"],
  }

  class { "::apache":
    mpm_module => 'prefork',
    default_vhost => false,
  }
  class { "::apache::mod::php": }

  apache::vhost { "exim4u":
    vhost_name => "*",
    port => 80,
    docroot => "/usr/local/exim4u/home/exim4u/public_html/exim4u",
  }

  file { "/usr/local/exim4u/home/exim4u/public_html/exim4u/config/variables.php":
    require => Vcsrepo["/usr/local/exim4u/"],
    content => template("exim4u/variables.php"),
  }
  file { "/usr/local/exim4u/home/exim4u/public_html/exim4u/config/functions.php":
    require => Vcsrepo["/usr/local/exim4u/"],
    content => template("exim4u/functions.php"),
  }

  service { "dovecot":
    ensure => running,
  }
  file { "/etc/dovecot/dovecot-sql.conf.ext":
    ensure => present,
    content => template("exim4u/etc/dovecot/dovecot-sql.conf.erb"),
    require => Package["dovecot-mysql"],
    mode => '0660',
    notify => Service["dovecot"],
  }
  file { "/etc/dovecot/conf.d/10-ssl.conf":
    ensure => present,
    content => template("exim4u/etc/dovecot/conf.d/10-ssl.conf.erb"),
    require => Package["dovecot-mysql"],
    mode => '0660',
    notify => Service["dovecot"],
  }
  file { "/etc/dovecot/conf.d/10-auth.conf":
    ensure => present,
    content => template("exim4u/etc/dovecot/conf.d/10-auth.conf.erb"),
    require => Package["dovecot-mysql"],
    mode => '0660',
    notify => Service["dovecot"],
  }
  file { "/etc/dovecot/conf.d/10-mail.conf":
    ensure => present,
    content => template("exim4u/etc/dovecot/conf.d/10-mail.conf.erb"),
    require => Package["dovecot-mysql"],
    mode => '0660',
    notify => Service["dovecot"],
  }
  file { "/etc/dovecot/conf.d/15-mailboxes.conf":
    ensure => present,
    content => template("exim4u/etc/dovecot/conf.d/15-mailboxes.conf.erb"),
    require => Package["dovecot-mysql"],
    mode => '0660',
    notify => Service["dovecot"],
  }

  file { "/etc/pki":
    ensure => directory,
  }
  file { "/etc/pki/tls":
    ensure => directory,
  }
  file { "/etc/pki/tls/exim_tls":
    ensure => directory,
  }
  ::openssl::certificate::x509 { "exim":
    ensure => present,
    base_dir => "/etc/pki/tls/exim_tls",
    require => File["/etc/pki/tls/exim_tls"],
    commonname => $primary_hostname,
    country => 'RU',
    organization => 'Snake Oil, INC.',
    days => "3650",
    owner => "Debian-exim",
  }
}
