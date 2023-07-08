#include <Raven/Raven.h>
#include <Raven/UI.h>
#include <System/Syscall.h>
#include <Common/Alloc.h>
#include <Media/Graphics.h>
#include <System/Thread.h>
#include <Raven/Widgets/Button.h>

void TryZorroOS(RavenSession* session, ClientWindow* win, int64_t id) {
    CloseRavenSession(session);
    Exit(0);
}

int main() {
    RavenSession* session = NewRavenSession();
    ClientWindow* win = NewRavenWindow(session,640,480,0);
    if(win == NULL) {
        RyuLog("Unable to open window!\n");
        return 0;
    }
    NewButtonWidget(win,(320-64),480-149,16,50,"Try","Device/CD",&TryZorroOS);
    NewButtonWidget(win,(320-64)+64,480-149,0,50,"Install","File/Archive",NULL);
    UIRun(session,win,"zorroOS Installer","File/Archive");
}