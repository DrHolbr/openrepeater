<?php
// A backup file is data, not authority to run SQL. The reader accepts only the
// statements produced by sqlite3 .dump for the named tables: comments, the
// foreign_keys pragma, transaction wrappers, one CREATE TABLE per table, and
// INSERT rows made of literals. Anything else rejects the whole file.
class BackupSql {

	public static function parse($sql, array $tables) {
		if (!is_string($sql) || $sql === '' || strpos($sql, "\0") !== false) {
			return false;
		}
		$allowed = array();
		foreach ($tables as $table) {
			if (!is_string($table) || !preg_match('/^[A-Za-z_][A-Za-z0-9_]*$/', $table) || isset($allowed[$table])) {
				return false;
			}
			$allowed[$table] = true;
		}
		if ($allowed === array()) {
			return false;
		}
		$tokens = self::tokenize($sql);
		if ($tokens === false) {
			return false;
		}
		$statements = self::statements($tokens);
		if ($statements === false) {
			return false;
		}
		$rows = array();
		$created = array();
		foreach ($allowed as $table => $unused) {
			$rows[$table] = array();
			$created[$table] = 0;
		}
		foreach ($statements as $statement) {
			if (!self::accept($statement, $allowed, $rows, $created)) {
				return false;
			}
		}
		foreach ($created as $count) {
			if ($count !== 1) {
				return false;
			}
		}
		return $rows;
	}

	private static function accept($statement, $allowed, &$rows, &$created) {
		$n = count($statement);
		if ($n === 0) {
			return false;
		}
		if (self::kw($statement, 0, 'PRAGMA')) {
			return $n === 4
				&& self::kw($statement, 1, 'foreign_keys')
				&& $statement[2] === array('punct', '=')
				&& self::kw($statement, 3, 'OFF');
		}
		if (self::kw($statement, 0, 'BEGIN')) {
			if ($n === 1) {
				return true;
			}
			return $n === 2 && (
				self::kw($statement, 1, 'TRANSACTION')
				|| self::kw($statement, 1, 'DEFERRED')
				|| self::kw($statement, 1, 'IMMEDIATE')
				|| self::kw($statement, 1, 'EXCLUSIVE')
			);
		}
		if (self::kw($statement, 0, 'COMMIT') || self::kw($statement, 0, 'END')) {
			return $n === 1 || ($n === 2 && self::kw($statement, 1, 'TRANSACTION'));
		}
		if (self::kw($statement, 0, 'CREATE')) {
			$i = 1;
			if (!self::kw($statement, $i, 'TABLE')) {
				return false;
			}
			$i++;
			if (self::kw($statement, $i, 'IF')) {
				if (!self::kw($statement, $i + 1, 'NOT') || !self::kw($statement, $i + 2, 'EXISTS')) {
					return false;
				}
				$i += 3;
			}
			$name = self::name($statement, $i, $allowed);
			if ($name === null || !isset($statement[$i + 1]) || $statement[$i + 1] !== array('punct', '(')) {
				return false;
			}
			$created[$name]++;
			return true;
		}
		if (!self::kw($statement, 0, 'INSERT') || !self::kw($statement, 1, 'INTO')) {
			return false;
		}
		$name = self::name($statement, 2, $allowed);
		if ($name === null) {
			return false;
		}
		$i = 3;
		$columns = null;
		if (isset($statement[$i]) && $statement[$i] === array('punct', '(')) {
			$columns = array();
			$i++;
			while (isset($statement[$i]) && $statement[$i] !== array('punct', ')')) {
				$column = self::bare_name($statement, $i);
				if ($column === null) {
					return false;
				}
				$columns[] = $column;
				$i++;
				if (isset($statement[$i]) && $statement[$i] === array('punct', ',')) {
					$i++;
				}
			}
			if (!isset($statement[$i]) || $statement[$i] !== array('punct', ')') || $columns === array()) {
				return false;
			}
			$i++;
		}
		if (!self::kw($statement, $i, 'VALUES')) {
			return false;
		}
		$i++;
		$width = $columns === null ? null : count($columns);
		while ($i < $n) {
			if ($statement[$i] !== array('punct', '(')) {
				return false;
			}
			$i++;
			$values = array();
			while (isset($statement[$i]) && $statement[$i] !== array('punct', ')')) {
				$literal = self::literal($statement, $i);
				if ($literal === null) {
					return false;
				}
				$values[] = $literal[0];
				$i = $literal[1];
				if (isset($statement[$i]) && $statement[$i] === array('punct', ',')) {
					$i++;
				}
			}
			if (!isset($statement[$i]) || $statement[$i] !== array('punct', ')')) {
				return false;
			}
			$i++;
			if ($width === null) {
				$width = count($values);
			}
			if ($width === 0 || count($values) !== $width) {
				return false;
			}
			$rows[$name][] = array('columns' => $columns, 'values' => $values);
			if ($i < $n) {
				if ($statement[$i] !== array('punct', ',')) {
					return false;
				}
				$i++;
			}
		}
		return true;
	}

	private static function literal($tokens, $i) {
		if (!isset($tokens[$i])) {
			return null;
		}
		$tok = $tokens[$i];
		if ($tok[0] === 'punct' && $tok[1] === '-' && isset($tokens[$i + 1]) && $tokens[$i + 1][0] === 'number') {
			$number = $tokens[$i + 1];
			$number[1] = '-' . $number[1];
			return array($number, $i + 2);
		}
		if ($tok[0] === 'ident' && strcasecmp($tok[1], 'NULL') === 0) {
			return array(array('null', null), $i + 1);
		}
		if ($tok[0] === 'number' || $tok[0] === 'string' || $tok[0] === 'blob') {
			return array($tok, $i + 1);
		}
		return null;
	}

	private static function kw($tokens, $i, $word) {
		return isset($tokens[$i]) && $tokens[$i][0] === 'ident' && strcasecmp($tokens[$i][1], $word) === 0;
	}

	private static function name($tokens, $i, $allowed) {
		$bare = self::bare_name($tokens, $i);
		if ($bare === null || !isset($allowed[$bare])) {
			return null;
		}
		return $bare;
	}

	private static function bare_name($tokens, $i) {
		if (!isset($tokens[$i])) {
			return null;
		}
		$tok = $tokens[$i];
		if (($tok[0] !== 'ident' && $tok[0] !== 'quoted' && $tok[0] !== 'string') || !preg_match('/^[A-Za-z_][A-Za-z0-9_]*$/', $tok[1])) {
			return null;
		}
		return $tok[1];
	}

	private static function statements($tokens) {
		$statements = array();
		$current = array();
		$depth = 0;
		foreach ($tokens as $tok) {
			if ($tok[0] === 'punct' && $tok[1] === '(') {
				$depth++;
			} elseif ($tok[0] === 'punct' && $tok[1] === ')') {
				if ($depth === 0) {
					return false;
				}
				$depth--;
			}
			if ($tok[0] === 'punct' && $tok[1] === ';' && $depth === 0) {
				$statements[] = $current;
				$current = array();
				continue;
			}
			$current[] = $tok;
		}
		if ($current !== array() || $depth !== 0) {
			return false;
		}
		return $statements;
	}

	private static function tokenize($sql) {
		$tokens = array();
		$len = strlen($sql);
		$i = 0;
		while ($i < $len) {
			$c = $sql[$i];
			if ($c === ' ' || $c === "\t" || $c === "\n" || $c === "\r" || $c === "\f") {
				$i++;
				continue;
			}
			if ($c === '-' && $i + 1 < $len && $sql[$i + 1] === '-') {
				$i += 2;
				while ($i < $len && $sql[$i] !== "\n") {
					$i++;
				}
				continue;
			}
			if ($c === '/' && $i + 1 < $len && $sql[$i + 1] === '*') {
				$end = strpos($sql, '*/', $i + 2);
				if ($end === false) {
					return false;
				}
				$i = $end + 2;
				continue;
			}
			if ($c === '\'') {
				$value = '';
				$i++;
				$closed = false;
				while ($i < $len) {
					if ($sql[$i] === '\'') {
						if ($i + 1 < $len && $sql[$i + 1] === '\'') {
							$value .= '\'';
							$i += 2;
							continue;
						}
						$i++;
						$closed = true;
						break;
					}
					$value .= $sql[$i];
					$i++;
				}
				if (!$closed) {
					return false;
				}
				$tokens[] = array('string', $value);
				continue;
			}
			if ($c === '"' || $c === '`' || $c === '[') {
				$end = $c === '[' ? ']' : $c;
				$value = '';
				$i++;
				$closed = false;
				while ($i < $len) {
					if ($sql[$i] === $end) {
						if ($end !== ']' && $i + 1 < $len && $sql[$i + 1] === $end) {
							$value .= $end;
							$i += 2;
							continue;
						}
						$i++;
						$closed = true;
						break;
					}
					$value .= $sql[$i];
					$i++;
				}
				if (!$closed) {
					return false;
				}
				$tokens[] = array('quoted', $value);
				continue;
			}
			if (($c === 'x' || $c === 'X') && $i + 1 < $len && $sql[$i + 1] === '\'') {
				$i += 2;
				$hex = '';
				$closed = false;
				while ($i < $len) {
					if ($sql[$i] === '\'') {
						$i++;
						$closed = true;
						break;
					}
					$hex .= $sql[$i];
					$i++;
				}
				if (!$closed || $hex === '' || (strlen($hex) % 2) !== 0 || !ctype_xdigit($hex)) {
					return false;
				}
				$tokens[] = array('blob', hex2bin($hex));
				continue;
			}
			if (($c >= 'A' && $c <= 'Z') || ($c >= 'a' && $c <= 'z') || $c === '_') {
				$start = $i;
				$i++;
				while ($i < $len) {
					$d = $sql[$i];
					if (($d >= 'A' && $d <= 'Z') || ($d >= 'a' && $d <= 'z') || ($d >= '0' && $d <= '9') || $d === '_') {
						$i++;
						continue;
					}
					break;
				}
				$tokens[] = array('ident', substr($sql, $start, $i - $start));
				continue;
			}
			if ($c >= '0' && $c <= '9') {
				$start = $i;
				$i++;
				while ($i < $len && $sql[$i] >= '0' && $sql[$i] <= '9') {
					$i++;
				}
				if ($i < $len && $sql[$i] === '.') {
					$i++;
					if ($i >= $len || $sql[$i] < '0' || $sql[$i] > '9') {
						return false;
					}
					while ($i < $len && $sql[$i] >= '0' && $sql[$i] <= '9') {
						$i++;
					}
				}
				if ($i < $len && ($sql[$i] === 'e' || $sql[$i] === 'E')) {
					$i++;
					if ($i < $len && ($sql[$i] === '+' || $sql[$i] === '-')) {
						$i++;
					}
					if ($i >= $len || $sql[$i] < '0' || $sql[$i] > '9') {
						return false;
					}
					while ($i < $len && $sql[$i] >= '0' && $sql[$i] <= '9') {
						$i++;
					}
				}
				$tokens[] = array('number', substr($sql, $start, $i - $start));
				continue;
			}
			if ($c === '(' || $c === ')' || $c === ',' || $c === ';' || $c === '=') {
				$tokens[] = array('punct', $c);
				$i++;
				continue;
			}
			return false;
		}
		return $tokens;
	}
}
