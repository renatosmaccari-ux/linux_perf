					if (! val.host ) {			// xoruxfork: val.hosts pode nao existir
						// Um registro OracleDB incompleto - gravado com uuid e
						// dataguard, sem host nem hosts - fazia val.hosts[0]
						// lancar TypeError aqui. O $.each abortava, o callback
						// de cmd=json junto, e a pagina inteira ficava sem
						// nenhuma linha na tabela e com New, Edit, Clone,
						// Delete e Connection Test mortos. Um registro ruim
						// derrubava todos os outros.
						val.host = ( val.hosts && val.hosts[0] ) ? val.hosts[0] : "";
					}
