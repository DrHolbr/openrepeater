<?php
###########################################################################################
# Class Autoloader
# __autoload() was removed in PHP 8. spl_autoload_register() is the PHP 7 and 8 path.
###########################################################################################

spl_autoload_register(function ($class_name) {
    // Only OpenRepeater classes live in this directory. Optional PHP
    // extensions such as Memcached are not files here. Returning leaves
    // class_exists() false when the extension is absent. Instantiating a
    // missing OpenRepeater class still raises "Class not found".
    if (!is_string($class_name) || !preg_match('/^[A-Za-z_][A-Za-z0-9_]*$/', $class_name)) {
        return;
    }
    $root = isset($_SERVER['DOCUMENT_ROOT']) ? rtrim($_SERVER['DOCUMENT_ROOT'], '/') : '';
    if ($root === '') {
        return;
    }
    $file = $root . '/includes/classes/' . $class_name . '.php';
    if (is_file($file)) {
        require_once $file;
    }
});
?>
