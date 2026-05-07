MEMORY
{
  rom      (rx)  : ORIGIN = 0x00000000, LENGTH = 0x00020000
  ram      (rwx) : ORIGIN = 0x00800000, LENGTH = 0x00020000
}

STACK_SIZE = 0x2000;
TEST_STATUS_ORIGIN = ORIGIN(ram) + LENGTH(ram) - 0x1000;
TEST_STATUS_SIZE = 0x1000;

SECTIONS
{
    .text :
    {
        KEEP(*(.vectors .vectors.*));
        *(.text .text.*);
        *(.rodata .rodata.*);
        . = ALIGN(4);
        _sctors = .;
        KEEP(*(SORT(.ctors.*)));
        KEEP(*(.ctors));
        . = ALIGN(4);
        _ectors = .;
        _etext = .;
    } > rom

    . = .;

    .bss (NOLOAD) :
    {
        KEEP(*(.sprite_buffer .sprite_buffer.*));
        KEEP(*(.gui_buffer .gui_buffer.*));
        _sbss = . ;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(2);
        _ebss = . ;
    } > ram

    .data :
    {
        _sdata = .;
        *(.data*);
        . = ALIGN(2);
        _edata = .;
    } > ram AT >rom

    .stack (NOLOAD):
    {
        . = ALIGN(2);
        _sstack = .;
        . = . + STACK_SIZE;
        . = ALIGN(2);
        _estack = .;
    } > ram

    .test_status TEST_STATUS_ORIGIN (NOLOAD):
    {
        . = ALIGN(2);
        _stest_status = .;
        KEEP(*(.test_status .test_status.*));
        . = ALIGN(2);
        _etest_status = .;
    } > ram

    ASSERT(_estack <= TEST_STATUS_ORIGIN, "test ROM stack overlaps .test_status")
    ASSERT(SIZEOF(.test_status) <= TEST_STATUS_SIZE, ".test_status exceeds reserved work RAM area")

    . = ALIGN(2);
    _end = . ;
}
