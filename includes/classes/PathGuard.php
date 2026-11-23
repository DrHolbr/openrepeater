<?php
# Path checks used by uploads, backups, and config writes.
# A symlink is not followed. A delete stays inside its parent directory.

class PathGuard {

	public static function componentsAreReal($path) {
		if (!is_string($path) || $path === '' || $path[0] !== '/') {
			return false;
		}
		if (strpos($path, "\0") !== false || strpos($path, '..') !== false) {
			return false;
		}
		$parts = explode('/', $path);
		$acc = '';
		$last = count($parts) - 1;
		for ($i = 0; $i <= $last; $i++) {
			$part = $parts[$i];
			if ($part === '') {
				continue;
			}
			if ($part === '.' || $part === '..') {
				return false;
			}
			$acc .= '/' . $part;
			if (is_link($acc)) {
				return false;
			}
			if (!file_exists($acc) && $i !== $last) {
				return false;
			}
		}
		return true;
	}

	public static function pathInside($root, $path) {
		$root = rtrim((string) $root, '/');
		$path = rtrim((string) $path, '/');
		return $path === $root || strpos($path, $root . '/') === 0;
	}

	// Delete a file or directory only when it is a real child of $parent.
	// A symlink is unlinked and is not followed.
	public static function removeTreeConfined($path, $parent) {
		if (!is_string($path) || !is_string($parent) || $path === '' || $parent === '') {
			return false;
		}
		if (is_link($parent) || !is_dir($parent)) {
			return false;
		}
		$parentReal = realpath($parent);
		if ($parentReal === false) {
			return false;
		}
		if (!file_exists($path) && !is_link($path)) {
			return true;
		}
		if (is_link($path)) {
			$dir = dirname($path);
			if (is_link($dir) || !is_dir($dir)) {
				return false;
			}
			$dirReal = realpath($dir);
			if ($dirReal === false || !self::pathInside($parentReal, $dirReal)) {
				return false;
			}
			return unlink($path);
		}
		if (!is_dir($path)) {
			$dirReal = realpath(dirname($path));
			$fileReal = realpath($path);
			if ($dirReal === false || $fileReal === false || !self::pathInside($parentReal, $dirReal) || !self::pathInside($parentReal, $fileReal) || $fileReal === $parentReal) {
				return false;
			}
			return unlink($path);
		}
		$real = realpath($path);
		if ($real === false || !self::pathInside($parentReal, $real) || $real === $parentReal) {
			return false;
		}
		return self::removeTreeWalk($real, $parentReal);
	}

	private static function removeTreeWalk($dir, $root) {
		if (is_link($dir)) {
			return unlink($dir);
		}
		if (!is_dir($dir) || !self::pathInside($root, $dir) || $dir === $root) {
			return false;
		}
		$list = scandir($dir);
		if (!is_array($list)) {
			return false;
		}
		foreach ($list as $name) {
			if ($name === '.' || $name === '..') {
				continue;
			}
			$child = $dir . '/' . $name;
			if (is_link($child)) {
				if (!unlink($child)) {
					return false;
				}
				continue;
			}
			if (is_dir($child)) {
				if (!self::removeTreeWalk($child, $root)) {
					return false;
				}
				continue;
			}
			if (!unlink($child)) {
				return false;
			}
		}
		return rmdir($dir);
	}

	public static function writeContained($path, $data) {
		if (!self::componentsAreReal($path) || is_link($path)) {
			return false;
		}
		$dir = dirname($path);
		if (!is_dir($dir) || is_link($dir) || !self::componentsAreReal($dir)) {
			return false;
		}
		$tmp = $dir . '/.' . basename($path) . '.' . getmypid() . '.tmp';
		if (@file_put_contents($tmp, $data) === false) {
			return false;
		}
		if (is_link($path)) {
			@unlink($tmp);
			return false;
		}
		if (!rename($tmp, $path)) {
			@unlink($tmp);
			return false;
		}
		return true;
	}


	public static function testFixture() {
		if (getenv('ORP_BENCH_TEST_HARNESS') !== '1') {
			return false;
		}
		return PHP_SAPI === 'cli' || PHP_SAPI === 'phpdbg' || PHP_SAPI === 'cli-server';
	}
}
