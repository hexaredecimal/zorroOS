#ifndef _LIBRAVEN_WIDGETS_LABEL_H
#include "../Widget.h"
#include "../Raven.h"
#include "../UI.h"

typedef struct {
    char selected;
    int cursorX;
    int cursorY;
    int scrollX;
    int scrollY;
    char** lines;
    int lineCount;
} UITextAreaPrivateData;

int64_t NewTextAreaWidget(ClientWindow* win, int dest, int x, int y, int w, int h);
int64_t NewTextBoxWidget(ClientWindow* win, int dest, int x, int y, int w, int h, const char* text);

#endif