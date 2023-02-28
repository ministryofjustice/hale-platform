<?php
/** Define ABSPATH as this file's directory */
if ( ! defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', dirname( __FILE__ ) . '/' );
}
if ( file_exists( ABSPATH . 'wp-load.php' ) ) {
    $message .= "[". date('h:i:s') ."] Loading WordPress: " . ABSPATH . "wp-load.php\n";
    include( ABSPATH . 'wp-load.php' );
}else{
    $message .= "[". date('h:i:s') ."] File does not exist: " . ABSPATH . "wp-load.php\n";
}

global $wpdb;
$sql = $wpdb->prepare("SELECT domain, path FROM $wpdb->blogs WHERE archived='0' AND deleted ='0' LIMIT 0,300", '');

$blogs = $wpdb->get_results($sql);

foreach($blogs as $blog) {
    $site_url = $blog->domain . ($blog->path ? $blog->path : '/');
    $output = shell_exec("wp cron event run --due-now --url='" . $site_url . "'");
}
//$output = shell_exec("wp cron event run --due-now --url='https://jotwpublic.prod.wp.dsd.io/playground/'");
//$output = shell_exec("wp cron event run --due-now --url='https://magistrates.judiciary.uk'");
//$output = shell_exec("wp cron event run --due-now --url='https://ccrc.gov.uk'");
//$output = shell_exec("wp cron event run --due-now --url='https://victimscommissioner.org.uk'");
//$output = shell_exec("wp cron event run --due-now --url='https://imb.org.uk'");
//$output = shell_exec("wp cron event run --due-now --url='https://publicdefenderservice.org.uk'");
