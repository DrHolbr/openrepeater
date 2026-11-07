<?php
###########################################################################################
# Class Autoloader
# __autoload() was removed in PHP 8. spl_autoload_register() is the PHP 7 and 8 path.
###########################################################################################

spl_autoload_register(function ($class_name) {
    $file = rtrim($_SERVER['DOCUMENT_ROOT'], '/') . '/includes/classes/' . $class_name . '.php';

    if (file_exists($file))
        require_once($file);
    else
        die('File Not Found: ' . $file);
});
?>
