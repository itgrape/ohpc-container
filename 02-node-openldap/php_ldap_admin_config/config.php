<?php

// system
$config->custom->session['blowfish'] = 'cb4aa1df3df4b15711b55a53f5f78ea9';
$config->custom->appearance['friendly_attrs'] = array(
    'facsimileTelephoneNumber' => 'Fax',
    'gid'                      => 'Group',
    'mail'                     => 'Email',
    'telephoneNumber'          => 'Telephone',
    'uid'                      => 'User Name',
    'userPassword'             => 'Password'
);
$servers = new Datastore();
$servers->newServer('ldap_pla');
$servers->setValue('server','name','Local LDAP Server');
$servers->setValue('appearance','pla_password_hash','md5');
$servers->setValue('login','attr','dn');

//custom
$servers->setValue('login','anon_bind',false);
$servers->setValue('login','allowed_dns',array('cn=admin,dc=pushihao,dc=com'));

$config->custom->session['reCAPTCHA-enable'] = false;
$config->custom->session['reCAPTCHA-key-site'] = '<put-here-key-site>';
$config->custom->session['reCAPTCHA-key-server'] = '<put-here-key-server>';

?>