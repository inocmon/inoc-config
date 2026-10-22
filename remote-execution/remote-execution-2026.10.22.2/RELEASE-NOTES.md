# remote-execution-2026.10.22.2

Aceita para piloto de produção em 2026-10-22. A implantação em produção permanece não validada: `production_deployment_validated=false`.

Esta revisão troca o Node da release .1 e preserva exatamente o Python. A sonda do contrato compartilha uma execução por binário, com prazo de 30 segundos. A resposta HTTP tem orçamento de 8 segundos e pode indicar pendência enquanto a sonda continua. O cache de sucesso dura até 60 segundos, com SHA atual e permissões do arquivo verificados; substituição ou falha invalidam a prontidão. A identidade também continua sendo conferida no lançamento do executor. Essa prontidão não comprova a saúde dos equipamentos da rede.

O provisionamento central usa a API autenticada do proxy, payload selado por RSA, worker systemd e lifecycle. Perda de ACK é reconciliada consultando o mesmo ID; duplicatas não iniciam outro worker. Estado unknown bloqueia novo intento até reconciliação. O lifecycle aplica as permissões necessárias aos diretórios do usuário dedicado sob `UMask=0077`, mantendo staging e segredos privados. O EnrollmentStore fixa modo 0600 apenas no lock criado pela própria operação, após conferir tipo, inode, dono e número de links; locks existentes inseguros continuam sendo recusados.

| Artefato | Bytes | SHA-256 |
| --- | ---: | --- |
| inoc-node-terminal-v1dot1beta39 | 128978112 | 91f9e262ef3d02f764978f6d0cdc5eb4836375e1ab150fff12162edef5401961 |
| inoc-node-terminal-v1dot1beta39.gz | 42534609 | 052cbadab55b06cd3cdb9a27c5d4df582c8399c43ef7400dc907f18d2b59da25 |
| inoc-config5 | 29366392 | 161ce0ae66fa39f31d60c79befe9c252fbc4d09c5526675bbad3f071e0cbcb8a |

Fonte do build Node: `7755b33f46a895fde6c9c996a9ab3fb86cc717c3`. Fonte do Python: `f2b13efb28cceaa6ddc695d74efd2ccd2f086f0b`. Snapshot final das fontes: `24f8b84f0ee7d6d89515d52e6a761d5f1d6026ce`. Central validado: `dd0fa769cbcef2d5cd5d84909b1ca0dc19c99e48`. O snapshot posterior não é atribuído como fonte de build dos binários.

| Componente de suporte | SHA-256 |
| --- | --- |
| Instalador | e29d7f1fc4e9b15af65afde72b48cce3d0cd7322fefb79b93a330fe69b073c8e |
| Updater legado | f8e9e77df8d53807ac627f97b38498872f4673585780bf7a76367b316bc9bfda |
| Lifecycle | 78cb2036dcbe844eee0930bb3f5d66d52b90309b2f7d8fefe577c85e5715ebfa |
| Worker API | 8dc14156a8f383868366121cc8ca78871b57840e71037371be9c0d2764a814a2 |
| Transporte API | ad2a9d2e172e582eca2a7e4e1f54faab8150586bb9d1500753c23d0f5bed58b2 |
| Provisionador API | 072660ad058d1172db603129156e586d2f12231cd06c67caf612544b01b58567 |
| EnrollmentStore | 38c3d08e0dd91e5fad093f03b70137d71c5c2cef9de6e221a73a2ff1c1969ef9 |

A verificação estática confirmou os sete hashes esperados, 13/13 cópias centrais do snapshot, todas as 16 referências de SOURCE-SNAPSHOT e as cópias diretas dos scripts. Recibo SHA-256: `94a6396cd04e36a7d600148050361e39c110a61ac947f1641273763815599c0c`.

| Validação | Resultado |
| --- | --- |
| [Build Node — execução 39845689973](https://github.com/inocmon/inoc-config-project/actions/runs/39845689973) | PASS, 25 testes |
| [Integração com binários congelados — execução 39846336498](https://github.com/inocmon/inoc-config-project/actions/runs/39846336498) | PASS |
| [Instalador — execução 39847829286](https://github.com/inocmon/inoc-config-project/actions/runs/39847829286) | PASS |
| [Migração beta37/beta38,39849396303](https://github.com/inocmon/inoc-config-project/actions/runs/39849396303) | PASS com updater f8e9e77 |
| [Lifecycle systemd — execução 39852968479](https://github.com/inocmon/inoc-config-project/actions/runs/39852968479) | PASS: instalação, atualização, rollback, TLS e quatro operações concorrentes sem replay |
| [API provisionamento — execução 39855586260](https://github.com/inocmon/inoc-config-project/actions/runs/39855586260) | PASS, seis cenários: normal, ACK perdido e worker morto em beta37/beta38 |
| [API matrícula failed .1 → .2,39855586253](https://github.com/inocmon/inoc-config-project/actions/runs/39855586253) | PASS em beta37/beta38: PID e hash instalados conferidos; chaves, histórico e release anterior preservados; duplicata sem replay |
| [Central — execução 39855563516](https://github.com/inocmon/inocmon6/actions/runs/39855563516) | PASS: 324 testes PHP, 65 JavaScript, 22 Chromium, verificações de ownership e suítes Python3.9/3.12 sem skips |

O consolidado dos recibos da API tem SHA-256 `4e8474cf3a8c5eec46cdb1b7ac6a9c319d963e904393ef152d39800e976dbd6f`. São testes com identidades sintéticas em rede loopback. A consulta SQL de operações pendentes e o cache de locks do cenário failed são fixtures; o resultado não prova exclusão distribuída em produção. As auditorias de sentinelas em argv/logs são limitadas aos cenários executados. Não foram executados comandos em equipamentos reais.

No lifecycle, as quatro operações concluíram dentro dos limites de 256MiB, swap0 e 64 tarefas; a amostragem atingiu 256MiB e 23 tarefas. O runner não forneceu contadores kernel de OOM nem pico exato; o aceite não declara OOM=0 ou folga de memória. O wrapper executado configura `UMask=0077`; o recibo não inclui um dump separado dessa propriedade.

As tags novas são `inoc-config-remote-execution-v2026.10.22.2` e `inoc-config-source-remote-execution-v2026.10.22.2`. O release_id .2 e os hashes distinguem este conjunto, embora o executável mantenha o nome beta39. O pacote gzip é materializado pelo fluxo existente. Os arquivos e tags da .1 permanecem imutáveis; a mudança de gitlink central isoladamente não reverte um executor dedicado já instalado. O rollback usa o lifecycle e os registros operacionais preservados.
