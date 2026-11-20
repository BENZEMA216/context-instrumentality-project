on run
	set runtimePath to (POSIX path of (path to home folder)) & ".local/share/context-vault/runtime/bin/context-vault"
	try
		do shell script (quoted form of runtimePath & " launch")
	on error errText
		display alert "Context Vault" message errText as critical
	end try
end run
