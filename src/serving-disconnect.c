#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>
#include <R_ext/Visibility.h>
#ifndef _WIN32
#include <signal.h>
#include <pthread.h>
#endif

/* Change only the calling thread's SIGPIPE mask. Windows has no POSIX SIGPIPE. */
static SEXP block_serving_sigpipe(void) {
#ifdef _WIN32
    return Rf_ScalarLogical(FALSE);
#else
    sigset_t pipe, previous;
    SEXP changed = PROTECT(Rf_allocVector(LGLSXP, 1));
    sigemptyset(&pipe);
    sigaddset(&pipe, SIGPIPE);
    if (pthread_sigmask(SIG_BLOCK, &pipe, &previous) != 0)
        Rf_error("Could not guard database disconnect");
    LOGICAL(changed)[0] = sigismember(&previous, SIGPIPE) == 0;
    UNPROTECT(1);
    return changed;
#endif
}

static SEXP unblock_serving_sigpipe(void) {
#ifndef _WIN32
    sigset_t pipe;
    sigemptyset(&pipe);
    sigaddset(&pipe, SIGPIPE);
    if (pthread_sigmask(SIG_UNBLOCK, &pipe, NULL) != 0)
        Rf_error("Could not restore database disconnect signal mask");
#endif
    return R_NilValue;
}

static const R_CallMethodDef calls[] = {
    {"block_serving_sigpipe", (DL_FUNC) &block_serving_sigpipe, 0},
    {"unblock_serving_sigpipe", (DL_FUNC) &unblock_serving_sigpipe, 0},
    {NULL, NULL, 0}
};

void attribute_visible R_init_AchillesNext(DllInfo *dll) {
    R_registerRoutines(dll, NULL, calls, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
    R_forceSymbols(dll, TRUE);
}
