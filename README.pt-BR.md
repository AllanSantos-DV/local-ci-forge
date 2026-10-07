# local-ci-forge

**Rode o GitHub Actions na sua própria máquina Windows + WSL: os mesmos workflows, as mesmas releases, sem o teto de minutos do runner hospedado.**

[English](README.md) · [Site](https://allansantos-dv.github.io/local-ci-forge/) · [Changelog](CHANGELOG.md)

O local-ci-forge transforma uma estação Windows 11 num conjunto de **runners self-hosted** do GitHub (Windows
nativo e Linux no WSL) e manda os jobs de cada repositório para ela com uma variável de repositório. Ele já
traz as correções que só aparecem quando se roda CI de verdade numa máquina que também é usada no dia a dia:
Python por runner, Dev Drive, paralelismo seguro, métricas, dashboard e alertas.

## Por quê

Em repositório privado, o runner hospedado do GitHub cobra por minuto de uma cota mensal, e minuto de Windows
e macOS custa mais que o de Linux. Quem lança muitas versões fica sem minutos antes do fim do mês, e aí CI, CD e
releases param. Pela documentação do GitHub, o uso do Actions é gratuito em runner self-hosted
([GitHub Docs](https://docs.github.com/en/billing/concepts/product-billing/github-actions)).

## Como funciona

Cada job usa:

```yaml
runs-on: ${{ vars.CI_RUNNER == 'local' && fromJSON('["self-hosted","Linux"]') || 'ubuntu-latest' }}
```

- `CI_RUNNER=local`: roda nos runners desta máquina (Windows em `<runnerRoot>\<repo>-wN`, WSL em `~/actions-runner/<repo>-lN`).
- vazio ou `hosted`: roda no GitHub (bypass, por exemplo com a máquina desligada).

## Instalação

```powershell
git clone https://github.com/AllanSantos-DV/local-ci-forge
cd local-ci-forge
Copy-Item config\forge.example.json forge.json
notepad forge.json        # owner, repos e quantidade de runners
.\install.ps1             # pede UAC duas vezes (Dev Drive e tarefa de logon)
```

Requisitos: Windows 11, WSL 2 com Ubuntu (sudo sem senha), PowerShell 7, Git for Windows, GitHub CLI logado com
admin nos repos, Python 3.10+. **Só para repositórios privados.**

## Integrar um repositório

1. `python tools\route_workflows.py C:\caminho\do\repo`: reescreve o `runs-on` e desliga o restore de cache no runner local. Revise o diff e abra um PR.
2. **Leia cada workflow antes**: o que age sobre o desktop ou toca serviços de produção fica de fora (`--exclude arquivo.yml`).
3. `gh variable set CI_RUNNER -b local -R <owner>/<repo>`. Antes disso, nada muda.

## Uso diário

```powershell
python tools\report.py --days 1          # relatório em texto
python tools\dashboard.py --open         # dashboard HTML: projetos, runners, jobs, minutos economizados
.\windows\sync-runners.ps1               # aplica a quantidade de runners do forge.json
.\windows\restart-runners.ps1            # depois de mudar scripts ou forge.json (sem UAC)
```

O dimensionamento, a segurança e o troubleshooting completo estão no [README em inglês](README.md#sizing).

## Licença

[MIT](LICENSE)
