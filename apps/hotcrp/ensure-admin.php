<?php
require_once __DIR__ . "/src/init.php";

$dbName = getenv("HOTCRP_DB_NAME") ?: null;
$conf = initialize_conf(null, $dbName);
$email = getenv("HOTCRP_ADMIN_EMAIL") ?: "admin@example.com";
$password = getenv("HOTCRP_ADMIN_PASSWORD") ?: "Password123!";
$user = $conf->user_by_email($email);
if (!$user) {
    fwrite(STDERR, "HotCRP admin account not found: {$email}\n");
    exit(1);
}
$user->change_password($password);
