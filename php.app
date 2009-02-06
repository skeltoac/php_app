{application, php,
 [
  {mod,
   {php_app,
	[
	 %% php processes to use
	 %% default: erlang:system_info(logical_processors)
	 % {procs, 2},
	 {opts,[
			%% path to PHP CLI binary
			%{php, "/usr/local/bin/php"},
			%% working dir for PHP (docroot?)
			%{dir, "/home/skeltoac/public_html"},
			%% initial PHP commands (includes?)
			%{init, "require('wp-config.php');"},
			%% default maximum memory allowed (Kib or infinity)
			{maxmem, 102400}
		   ]}]
   }
  }
 ]
}.
