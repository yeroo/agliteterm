#include <cstdio>
#include <cstdlib>
#include <cstring>
int main(int argc, char** argv) {
    if(argc!=5 || std::strcmp(argv[1],"init") || std::strcmp(argv[2],"pwsh") || std::strcmp(argv[3],"--config") || std::strcmp(argv[4],"C:\\test's theme.omp.json"))return 7;
    const char* mode=std::getenv("AGLITE_OMP_UNIT_MODE");
    if(mode && !std::strcmp(mode,"error")){std::puts("throw 'initializer failure'");return 0;}
    std::puts("$global:ompApplied++");
    if(mode && !std::strcmp(mode,"change"))std::puts("function global:prompt { 'OMP-CHANGED' }");
    return mode && !std::strcmp(mode,"fail") ? 9 : 0;
}
