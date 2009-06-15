{application, php,
 [
  {mod,
   {php_app,
	[
	 %% number of php processes to use
	 %% default if procs not specified: erlang:system_info(logical_processors)
	 {procs, 3},
	 {opts,[
			%% path to PHP CLI binary
			{php, "/usr/bin/php -c /usr/lib/php-cli.ini"},
			%% working dir for PHP (docroot?)
			%{dir, "/home/skeltoac/public_html"},
			%% initial PHP commands (includes?)
			{init, "require('wcdb-include.php');"},
			%% default maximum memory allowed (Kib or infinity)
			{maxmem, 102400}
		   ]}]
   }
  }
 ]
}.
