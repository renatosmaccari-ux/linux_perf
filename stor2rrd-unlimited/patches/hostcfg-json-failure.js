			}
		}).fail(function (jq, st, err) {			// xoruxfork: hosts.sh cmd=json
			// Every button on this page is bound inside the cmd=json callback.
			// Without this branch a failed request leaves New, Edit, Clone,
			// Delete and Connection Test rendered but dead, the host table
			// empty, and nothing on screen explaining why.
			var msg = "Nao foi possivel carregar a configuracao de hosts "
				+ "(/lpar2rrd-cgi/hosts.sh?cmd=json): " + jq.status + " "
				+ (err || st) + ".<br>Enquanto isso os botoes New, Edit, Clone, "
				+ "Delete e Connection Test ficam inativos.<br>Verifique o log de "
				+ "erro do servidor web e se o usuario do web server consegue ler "
				+ "etc/web_config/hosts.json.";
			try { $.message(msg, "Configuracao de hosts indisponivel"); }
			catch (e) {
				$("#cfgcomment").prepend("<p style='color:red'>" + msg + "</p>");
			}
		});
		if (sysInfo.free == 1) {
