# 💾 Backup e Restore do Mac

Um script simples que **copia seus arquivos, a lista dos seus aplicativos e as configurações do seu Mac para um HD externo** — e que depois **coloca tudo de volta** em um Mac novo (ou no mesmo Mac, depois de uma formatação).

> Pense nele como uma "mudança de casa" para o seu Mac: ele empacota suas coisas no HD externo e, na casa nova, desempacota tudo no lugar certo.

---

## 📋 Índice

1. [O que ele guarda](#-o-que-ele-guarda)
2. [O que você vai precisar](#-o-que-você-vai-precisar)
3. [Preparação (só na primeira vez)](#-preparação-só-na-primeira-vez)
4. [Fazendo o backup](#-fazendo-o-backup)
5. [Restaurando em um Mac novo](#-restaurando-em-um-mac-novo)
6. [Outros comandos úteis](#-outros-comandos-úteis)
7. [Perguntas frequentes](#-perguntas-frequentes)
8. [Deu erro? Veja aqui](#-deu-erro-veja-aqui)

---

## 📦 O que ele guarda

| O quê | Exemplos |
|---|---|
| **Seus arquivos** | Documentos, Mesa (Desktop), Downloads, Imagens, Filmes, Músicas, pastas de projetos |
| **A lista dos seus aplicativos** | Apps instalados pela App Store e pelo Homebrew, para reinstalar automaticamente |
| **Configurações dos aplicativos** | Preferências do sistema e de apps, fontes instaladas, configurações de editores (VS Code, JetBrains etc.) |
| **Configurações do Terminal e ferramentas** | Arquivos como `.zshrc`, chaves SSH, configurações do Git |

**O que ele NÃO guarda:** arquivos temporários, caches (que o próprio Mac recria) e pastas pesadas de programação que podem ser baixadas de novo (como `node_modules`).

### Como funcionam as cópias

Cada vez que você faz um backup, o script cria uma **"foto" (snapshot)** do seu Mac naquele momento, com data e hora no nome.

- O **primeiro** backup copia tudo e pode demorar.
- Os **seguintes** são bem mais rápidos: só copiam o que mudou. Mesmo assim, cada "foto" fica completa — você pode restaurar qualquer uma delas.
- Por padrão, ele guarda as **7 fotos mais recentes** e apaga as mais antigas automaticamente para não lotar o HD.

---

## 🧰 O que você vai precisar

- ✅ Um Mac com macOS
- ✅ Um **HD externo** (ou SSD) com espaço livre maior do que os seus arquivos
- ✅ Uns 15 minutos para a preparação da primeira vez

---

## 🛠 Preparação (só na primeira vez)

### Passo 1 — Formate o HD externo (recomendado)

> ⚠️ **Atenção: formatar apaga tudo o que está no HD.** Se ele já tem arquivos importantes, copie-os para outro lugar antes.

1. Conecte o HD no Mac.
2. Abra o **Utilitário de Disco** (aperte `⌘ Command` + `Espaço`, digite *Utilitário de Disco* e aperte `Enter`).
3. No menu à esquerda, clique no nome do seu HD.
4. Clique em **Apagar** (no topo da janela).
5. Preencha:
   - **Nome:** `BackupMac` (use exatamente esse nome para facilitar)
   - **Formato:** `APFS (Criptografado)`
6. Crie uma senha **e anote em um lugar seguro**. Sem ela, ninguém (nem você) abre o backup.
7. Clique em **Apagar** e aguarde.

> 💡 **Por que criptografado?** O backup contém coisas sensíveis, como chaves de acesso e senhas salvas por programas. Se o HD for perdido ou roubado, ninguém consegue ler o conteúdo.

### Passo 2 — Dê permissão ao Terminal

O Terminal é o aplicativo onde vamos "rodar" o script. Ele precisa de permissão para ler todos os seus arquivos:

1. Abra **Ajustes do Sistema** (ícone de engrenagem ⚙️).
2. Vá em **Privacidade e Segurança** → **Acesso Total ao Disco**.
3. Ative a chave ao lado de **Terminal**. (Se ele não estiver na lista, clique em **+**, vá em *Aplicativos → Utilitários* e escolha *Terminal*.)
4. Se o Terminal estiver aberto, feche e abra de novo.

### Passo 3 — Baixe o script

1. Nesta página do GitHub, clique no botão verde **`<> Code`** → **Download ZIP**.
2. Abra a pasta **Downloads** e dê dois cliques no arquivo `.zip` para descompactar.
3. Você terá uma pasta chamada `BackupRestoreMacOS-...` com o arquivo `macbackup.sh` dentro.

### Passo 4 — Abra o Terminal na pasta do script

1. Abra o **Terminal** (`⌘ Command` + `Espaço`, digite *Terminal*, `Enter`).
2. Digite `cd ` (com um espaço depois) — **não aperte Enter ainda**.
3. Arraste a pasta `BackupRestoreMacOS-...` do Finder para dentro da janela do Terminal. O caminho aparece sozinho.
4. Agora aperte `Enter`.

### Passo 5 — Libere o script para rodar

Copie e cole no Terminal, depois aperte `Enter`:

```bash
chmod +x macbackup.sh
```

> Não aparece nenhuma mensagem? Ótimo, deu certo! 🎉

### Passo 6 — Instale o Homebrew (recomendado)

O **Homebrew** é um "instalador de programas" para Mac. O script usa ele para anotar seus apps e reinstalá-los depois automaticamente.

1. Acesse **[brew.sh](https://brew.sh/pt-br/)**, copie o comando que aparece na página, cole no Terminal e aperte `Enter`.
2. Ele vai pedir a **senha do seu Mac**. Ao digitar, **nada aparece na tela** — isso é normal. Digite e aperte `Enter`.
3. Ao final, siga as instruções em "Next steps" que aparecem no Terminal (normalmente são 2 comandos para copiar e colar).
4. Depois, instale duas ferramentas auxiliares:

```bash
brew install rsync mas
```

> - **rsync** faz as cópias de forma mais completa.
> - **mas** anota os aplicativos da App Store.

### Passo 7 — Crie o arquivo de configuração (opcional)

```bash
./macbackup.sh init
```

Isso cria um arquivo chamado `.macbackup.conf` na sua pasta pessoal, onde você pode mudar:

- o **nome do HD** (se não usou `BackupMac`);
- **quais pastas** entram no backup;
- **quantas fotos** manter no HD.

Para editar, rode:

```bash
open -e ~/.macbackup.conf
```

> Se você deu ao HD o nome `BackupMac`, pode pular este passo — o padrão já funciona.

---

## 💾 Fazendo o backup

1. Conecte o HD externo (e digite a senha dele, se pedir).
2. **Ligue o Mac na tomada** — backups longos gastam bateria.
3. Abra o Terminal na pasta do script (veja o [Passo 4](#passo-4--abra-o-terminal-na-pasta-do-script)).
4. Rode:

```bash
./macbackup.sh backup
```

Pronto! O script vai mostrar o que está fazendo. Enquanto ele roda, **o Mac não entra em repouso**. No final você verá:

- ✅ **"Concluído sem avisos"** — tudo certo.
- ⚠️ **"Concluído com X aviso(s)"** — o backup foi feito, mas algo merece atenção (leia as linhas com `!`).
- ❌ **"Concluído com X erro(s)"** — veja a seção [Deu erro?](#-deu-erro-veja-aqui).

> 💡 **Quer testar antes, sem gravar nada?** Rode `./macbackup.sh backup --dry-run`. Ele só simula.

> 💡 **Com que frequência?** Uma vez por semana é um bom hábito. Antes de formatar ou trocar de Mac, **sempre**.

---

## ♻️ Restaurando em um Mac novo

Use isto quando comprar um Mac novo ou depois de formatar o seu.

1. No Mac novo, faça os passos **2, 3, 4 e 5** da [Preparação](#-preparação-só-na-primeira-vez).
2. **Entre na App Store** com seu Apple ID (para os apps de lá serem reinstalados).
3. **Feche todos os aplicativos**, deixando aberto só o Terminal.
4. Conecte o HD externo.
5. Rode:

```bash
./macbackup.sh restore
```

O script vai fazer algumas perguntas — responda digitando `s` (sim) ou `n` (não) e apertando `Enter`. A ordem é:

1. **Instala o Homebrew** (se precisar) e **reinstala seus aplicativos**. ☕ Pode demorar bastante e pedir a senha do Mac algumas vezes.
2. **Restaura as configurações** do Terminal e dos aplicativos.
3. **Copia seus arquivos** de volta para as pastas originais.

6. Ao final, **reinicie o Mac** para que todas as configurações sejam aplicadas.

> 📝 **Algum app não voltou?** Apps baixados direto de sites (fora da App Store e do Homebrew) precisam ser instalados à mão. O script cria um arquivo na sua Mesa chamado **`apps-para-instalar.txt`** com a lista deles.

> 🛟 **Segurança:** antes de substituir qualquer configuração que já exista no Mac, o script guarda uma cópia em uma pasta oculta chamada `.macbackup-safety` na sua pasta pessoal. Seus arquivos pessoais só são substituídos se a versão do backup for mais nova.

---

## 🧭 Outros comandos úteis

| Quero... | Comando |
|---|---|
| Ver os backups que existem no HD | `./macbackup.sh list` |
| Restaurar uma foto específica (use o nome mostrado no `list`) | `./macbackup.sh restore --snapshot 2026-09-26_132600` |
| Restaurar **só** os aplicativos | `./macbackup.sh restore --only apps` |
| Restaurar **só** os meus arquivos | `./macbackup.sh restore --only files` |
| Fazer backup só das configurações | `./macbackup.sh backup --only dotfiles,library` |
| Usar um HD com outro nome | `./macbackup.sh backup --volume /Volumes/NomeDoHD` |
| Copiar também os aplicativos inteiros (ocupa bem mais espaço) | `./macbackup.sh backup --with-apps` |
| Ver todas as opções | `./macbackup.sh --help` |

**Partes que podem ser usadas com `--only`:**

| Nome | O que é |
|---|---|
| `apps` | Aplicativos |
| `files` | Seus arquivos (Documentos, Mesa etc.) |
| `library` | Configurações dos aplicativos |
| `dotfiles` | Configurações do Terminal e ferramentas |
| `inventory` | (só no backup) A lista de apps instalados |

---

## ❓ Perguntas frequentes

**Isso substitui o Time Machine?**
Não precisa substituir — eles se complementam. O Time Machine copia o Mac inteiro. Este script é mais leve e focado em **montar um Mac novo do seu jeito**, reinstalando apps e configurações de forma organizada.

**Posso usar o mesmo HD para mais de um Mac?**
Pode. Cada Mac fica em uma pasta separada no HD, com o nome do computador.

**Quanto espaço vou precisar?**
Mais ou menos o tamanho das suas pastas pessoais. Os backups seguintes ocupam pouco, porque só guardam o que mudou.

**Posso usar o HD para outras coisas?**
Pode, desde que tenha espaço. Os backups ficam na pasta `MacBackups` — não mexa nela manualmente.

**Posso desligar o Mac no meio do backup?**
Evite. Mas se acontecer, sem problema: o backup incompleto é descartado automaticamente na próxima vez.

**E minhas senhas do Safari/Chaves (Keychain)?**
Essas ficam no **iCloud**. Ative *Ajustes do Sistema → [seu nome] → iCloud → Senhas e Chaves* nos dois Macs.

**E minhas fotos e documentos que já estão no iCloud?**
Eles voltam sozinhos quando você entra com seu Apple ID no Mac novo.

---

## 🆘 Deu erro? Veja aqui

| Mensagem | O que fazer |
|---|---|
| `Volume não encontrado: /Volumes/BackupMac` | O HD não está conectado ou tem outro nome. Conecte-o, ou use `--volume /Volumes/NomeDoSeuHD`. |
| `permission denied: ./macbackup.sh` | Rode o [Passo 5](#passo-5--libere-o-script-para-rodar) de novo. |
| `no such file or directory: ./macbackup.sh` | O Terminal não está na pasta do script. Refaça o [Passo 4](#passo-4--abra-o-terminal-na-pasta-do-script). |
| `O Terminal NÃO tem 'Acesso Total ao Disco'` | Refaça o [Passo 2](#passo-2--dê-permissão-ao-terminal) e reabra o Terminal. |
| `Volume NÃO criptografado` | É só um aviso. Para mais segurança, formate o HD como no [Passo 1](#passo-1--formate-o-hd-externo-recomendado). |
| `rsync do sistema em uso` | É só um aviso. Rode `brew install rsync` para cópias mais completas. |
| `Homebrew não instalado` | Veja o [Passo 6](#passo-6--instale-o-homebrew-recomendado). |
| Algum app da App Store não reinstalou | Entre na App Store com seu Apple ID e rode `./macbackup.sh restore --only apps` de novo. |

Todo backup e restore gera um **relatório (log)** com os detalhes. O caminho dele aparece na última linha da tela. Para abrir:

```bash
open "CAMINHO-QUE-APARECEU-NA-TELA"
```

Se ainda tiver dúvida, abra uma **[Issue](../../issues)** aqui no GitHub e cole a mensagem de erro.

---

## 📄 Licença

Distribuído sob a licença **Apache 2.0**. Veja o arquivo [LICENSE](LICENSE).

---

## 👤 Autor

Desenvolvido por **Eduardo Ferrari** — [DarkoCode](https://darkocode.com.br)
