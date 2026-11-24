#define _GNU_SOURCE
#include <ncurses.h>
#include <fcntl.h>
#include <locale.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

struct item { const char *label, *name, *cid, *digest, *size; };
#include "embedded.h"
enum { FILE_COUNT = sizeof catalog / sizeof catalog[0] };

static const char setup[] =
    "set -eo pipefail\n"
    "cli() { ./runtime/AppRun \"--config-dir=$PWD/session\" \"$@\"; }\n";
static const char start[] =
    "if cli daemon status 2>/dev/null | jq -e '.daemon.status == \"running\"' >/dev/null; then echo 'Daemon already running'; exit 1; fi\n"
    "if [[ ! -s devnet-sprs.json ]]; then echo 'Run the updated install.sh to refresh private devnet bootstrap records'; exit 1; fi\n"
    "tmp=$(mktemp .config.XXXXXXXX); trap 'rm -f \"$tmp\"' EXIT\n"
    "jq -e --slurpfile records devnet-sprs.json '($records[0] | select(type==\"array\" and length>0 and all(.[]; type==\"string\" and startswith(\"spr:\")))) as $nodes | "
    "del(.network, .\"no-bootstrap-node\") | .\"bootstrap-node\"=$nodes' config.json >\"$tmp\"\n"
    "mv \"$tmp\" config.json\n"
    "cli daemon start >>daemon.log 2>&1 </dev/null & pid=$!\n"
    "trap 'kill $pid 2>/dev/null || true' ERR\n"
    "for i in {1..30}; do kill -0 $pid; if cli module load storage_module; then break; fi; sleep 1; done\n"
    "cli call storage_module init \"@$PWD/config.json\" | jq -e '.result == true'\n"
    "cli call storage_module nodeConfig | jq -e --slurpfile nodes devnet-sprs.json "
    "'.result.value | if type==\"string\" then fromjson else . end | .\"bootstrap-node\" == $nodes[0]' "
    "|| { echo 'Effective bootstrap nodes do not match private devnet records'; kill $pid; exit 1; }\n"
    "cli call storage_module start | jq -e '.result == true'\n";
static const char status[] =
    "cli call storage_module debug | jq -er '.result.value | select(type==\"object\") | "
    "[\"Storage \\(.storage.version // \"unknown\")   Reachability \\(.nat.reachability // \"unknown\")\","
    "\"DHT peers \\(.table.nodes|length)   Connections \\(.connections|length)   SPR \\(if .spr then \"ready\" else \"pending\" end)\","
    "(.serviceProviders as $p | "
    "[($p[\"/mix/1.0.0\"]|length), ($p[\"/storage/dht-proxy/1.0.0\"]|length), "
    "($p[\"/libp2p/autonat/2/dial-request\"]|length), ($p[\"/libp2p/circuit/relay/0.2.0/hop\"]|length)] | "
    "\"Discovery \\(if all(.[]; .>0) then \"ready\" else \"incomplete\" end)   "
    "Mix \\(.[0])   DHT proxy \\(.[1])   AutoNAT \\(.[2])   Relay \\(.[3])\")] | .[]'";

// Commands run outside curses so input and log scrolling stay responsive.
static pid_t launch(const char *command, bool poll, const char *action, int selected) {
    pid_t pid = fork();
    if (pid != 0) return pid;
    setsid();
    if (action) {
        const struct item *item=&catalog[selected];
        setenv("ACTION",action,1); setenv("CID",item->cid,1);
        setenv("SIZE",item->size,1); setenv("DIGEST",item->digest,1);
        setenv("NAME",item->name,1);
    }
    if (!freopen("/dev/null", "r", stdin) ||
        !freopen(action ? "file-job.log" : poll ? "status.tmp" : "daemon.log", poll || action ? "w" : "a", stdout) ||
        (action ? dup2(STDOUT_FILENO, STDERR_FILENO)<0 : !freopen(poll ? "/dev/null" : "daemon.log", "a", stderr))) _exit(126);
    char *script;
    if (asprintf(&script, "%s%s", setup, command) < 0) _exit(126);
    execlp("bash", "bash", "-c", script, (char *)NULL);
    _exit(127);
}

// Find the previous newline by blocks. Even a multi-megabyte line costs 4 KiB.
static off_t previous(int fd, off_t end) {
    char buf[4096];
    off_t pos = end > 0 ? end - 1 : 0;
    while (pos > 0) {
        size_t size = pos < (off_t)sizeof buf ? (size_t)pos : sizeof buf;
        pos -= size;
        ssize_t got = pread(fd, buf, size, pos);
        if (got <= 0) break;
        for (ssize_t i = got; i-- > 0;) if (buf[i] == '\n') return pos+i+1;
    }
    return 0;
}

static off_t next_line(int fd, off_t pos, off_t end) {
    char buf[4096];
    while (pos < end) {
        ssize_t got = pread(fd, buf, sizeof buf, pos);
        if (got <= 0) break;
        char *nl = memchr(buf, '\n', got);
        if (nl) return pos + (nl-buf) + 1;
        pos += got;
    }
    return end;
}

static void line_at(int row, const char *s) {
    if (row < 0 || row >= LINES) return;
    move(row, 2);
    for (int col=0; *s && col<COLS-4; s++, col++) {
        unsigned char c=(unsigned char)*s;
        addch(c<32 || c==127 ? ' ' : c);
    }
}

static void panel(int top, int bottom, const char *title) {
    mvvline(top+1,0,ACS_VLINE,bottom-top-1);
    mvvline(top+1,COLS-1,ACS_VLINE,bottom-top-1);
    mvhline(top,1,ACS_HLINE,COLS-2);
    mvhline(bottom,1,ACS_HLINE,COLS-2);
    mvaddch(top,0,ACS_ULCORNER); mvaddch(top,COLS-1,ACS_URCORNER);
    mvaddch(bottom,0,ACS_LLCORNER); mvaddch(bottom,COLS-1,ACS_LRCORNER);
    attron(A_BOLD); line_at(top,title); attroff(A_BOLD);
}

static void job_message(char *buf, size_t capacity) {
    int fd=open("file-job.log",O_RDONLY);
    if (fd<0) return;
    off_t end=lseek(fd,0,SEEK_END);
    ssize_t n=pread(fd,buf,capacity-1,previous(fd,end));
    if (n>0) buf[n]=0;
    close(fd);
}

static volatile sig_atomic_t interrupted;
static void interrupt(int sig) { (void)sig; interrupted=1; }

int main(void) {
    char *root = getenv("LOGOS_DEVNET_HOME"), *base = getenv("XDG_DATA_HOME");
    char *executable = realpath("/proc/self/exe", NULL);
    if (!root && executable) {
        char *slash = strrchr(executable, '/');
        *slash = 0;
        char *marker;
        if (asprintf(&marker,"%s/installed",executable)<0) return 1;
        if (access(marker,R_OK)==0) root=executable;
        free(marker);
    }
    if (!root && asprintf(&root, "%s/%s", base ? base : getenv("HOME"),
                         base ? "logos-devnet" : ".local/share/logos-devnet") < 0) return 1;
    if (chdir(root) || access("installed", R_OK)) {
        fprintf(stderr, "Run install.sh first (expected installation in %s).\n", root);
        return 1;
    }
    char *home = realpath("home", NULL);
    if (!home || setenv("HOME", home, 1)) return 1;
    int lock = open("tui.lock", O_CREAT|O_RDWR|O_CLOEXEC, 0600);
    if (lock < 0 || flock(lock, LOCK_EX|LOCK_NB)) { perror("TUI lock"); return 1; }
    int log = open("daemon.log", O_CREAT|O_RDONLY|O_CLOEXEC, 0600);
    if (log < 0) { perror("daemon.log"); return 1; }
    setlocale(LC_ALL,"");
    initscr(); cbreak(); noecho(); keypad(stdscr,TRUE); curs_set(0); timeout(250);
    signal(SIGINT, interrupt); signal(SIGTERM, interrupt);
    pid_t worker=0, job=0;
    int selected=0;
    bool confirm=false;
    char file_message[256]="Select a file with Tab";
    const char *poll_script=
        "cli call storage_module manifests | jq -er '.result | select(.success) | .value | arrays | map(.cid) | .[], \"END\"' || echo UNKNOWN";
    char *snapshot;
    if (asprintf(&snapshot,"%s\n%s",status,poll_script)<0) { endwin(); return 1; }
    if (has_colors()) {
        start_color(); use_default_colors();
        init_pair(1,COLOR_GREEN,-1); init_pair(2,COLOR_RED,-1);
    }
    bool polling=false, online=false;
    off_t cursor=-1;
    time_t refresh=0;
    const char *message="";
    while (!interrupted) {
        int rc;
        if (worker>0 && waitpid(worker,&rc,WNOHANG)==worker) {
            bool ok=WIFEXITED(rc) && WEXITSTATUS(rc)==0;
            if (polling) {
                online=ok;
                if (ok) rename("status.tmp","status.txt");
                refresh=time(NULL)+3;
            } else { message=ok ? "Command completed" : "Command failed (see log)"; refresh=0; }
            worker=0;
        }
        if (job>0 && waitpid(job,&rc,WNOHANG)==job) {
            job=0; refresh=0;
            job_message(file_message,sizeof file_message);
            if (!WIFEXITED(rc) || WEXITSTATUS(rc)!=0) {
                char detail[180];
                snprintf(detail,sizeof detail,"%.175s",file_message);
                snprintf(file_message,sizeof file_message,"Failed: %s",detail);
            }
        }
        if (!worker && time(NULL)>=refresh) { polling=true; worker=launch(snapshot,true,NULL,0); }
        erase();
        if (LINES<19 || COLS<60) {
            line_at(0,"Enlarge terminal to 60 x 19");
            if (getch()=='q' && !job && (!worker || polling)) break;
            continue;
        }
        panel(0,5,online ? " NODE STATUS / online " : " NODE STATUS / offline or starting ");
        FILE *f = online ? fopen("status.txt","r") : NULL;
        char buf[4097];
        bool known=false, present[FILE_COUNT]={false};
        if (f) {
            for (int row=1; row<=3 && fgets(buf,sizeof buf,f); row++) line_at(row,buf);
            while (fgets(buf,sizeof buf,f)) {
                buf[strcspn(buf,"\n")]=0;
                if (!strcmp(buf,"END")) known=true;
                for (int i=0;i<FILE_COUNT;i++) if (!strcmp(buf,catalog[i].cid)) present[i]=true;
            }
            fclose(f);
        }
        line_at(4,*message ? message : "s Start   x Stop");
        panel(6,12," DEVNET FILES ");
        for (int i=0;i<FILE_COUNT;i++) {
            const char *presence=!known ? "Unknown" : present[i] ? "Present" : "Absent";
            snprintf(buf,sizeof buf,"%s %-8s  %s",selected==i ? ">" : " ",presence,catalog[i].label);
            int style=(selected==i ? A_BOLD : 0) | (known ? COLOR_PAIR(present[i]?1:2) : 0);
            attron(style); line_at(7+i,buf); attroff(style);
        }
        snprintf(buf,sizeof buf,"CID %s",catalog[selected].cid);
        line_at(9,buf);
        line_at(10,"Tab Select   d Direct   m Mix   r Remove");
        if (job>0) job_message(file_message,sizeof file_message);
        line_at(11,confirm ? "Remove selected CID locally?  y Yes / any other key cancels" : file_message);
        panel(13,LINES-2,cursor<0 ? " DAEMON LOG / live " : " DAEMON LOG / paused ");
        int row=14;
        off_t end=lseek(log,0,SEEK_END);
        if (cursor>end) cursor=-1;
        off_t pos=cursor<0 ? end : cursor;
        int rows=LINES-2-row;
        for (int y=LINES-3; y>=row && pos>0; y--) {
            off_t from=previous(log,pos), size=pos-from;
            ssize_t n=pread(log,buf,size>4096 ? 4096 : (size_t)size,from);
            if (n>0) { buf[n]=0;
                char *module=strstr(buf,"[storage_module] ");
                line_at(y,module ? module+strlen("[storage_module] ") : buf); }
            pos=from;
        }
        line_at(LINES-1,"s Start  x Stop  Arrows/PgUp/PgDn Scroll  End Live  q Quit");
        int key=getch();
        const char *action=NULL;
        if (confirm && key!=ERR) {
            if (key=='y') action="delete";
            confirm=false; key=ERR;
        }
        if (key=='\t') selected=(selected+1)%FILE_COUNT;
        if (online && !job && (!worker || polling)) {
            if (key=='d') action="direct";
            if (key=='m') action="mix";
            if (key=='r') confirm=true;
            if (action) {
                unlink("file-job.log");
                strcpy(file_message,"Starting operation...");
                job=launch(file_action,false,action,selected);
                if (job<0) {
                    job=0;
                    strcpy(file_message,"Could not start file operation");
                }
            }
        }
        if (key=='q' && !job && (!worker || polling)) break;
        if ((key=='s' || key=='x') && !job && (!worker || polling)) {
            if (worker>0) { kill(worker,SIGTERM); waitpid(worker,NULL,0); }
            polling=false; worker=launch(key=='s' ? start : "cli daemon stop",false,NULL,0);
            message=key=='s' ? "Starting node..." : "Stopping node...";
        }
        if (key==KEY_END) cursor=-1;
        if (key==KEY_UP || key==KEY_PPAGE) {
            off_t target=cursor<0 ? end : cursor;
            int count=key==KEY_UP ? 1 : rows;
            while (count-->0 && pos>0) { target=previous(log,target); pos=previous(log,pos); }
            cursor=target;
        }
        if ((key==KEY_DOWN || key==KEY_NPAGE) && cursor>=0) {
            int count=key==KEY_DOWN ? 1 : rows;
            while (count-->0 && cursor<end) cursor=next_line(log,cursor,end);
            if (cursor>=end) cursor=-1;
        }
    }
    endwin();
    return 0;
}
