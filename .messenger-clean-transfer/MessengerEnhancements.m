#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

static NSString *MPTranslateString(id value) {
    if (!value ||
        ![value isKindOfClass:[NSString class]]) {
        return value;
    }

    NSString *string = (NSString *)value;

    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        map = @{
            @"New Version Available : %@":
                @"Nova versão disponível: %@",
            @"Update":
                @"Atualizar",
            @"Cancel":
                @"Cancelar",
            @"Upload video to voice message":
                @"Enviar vídeo como mensagem de voz",
            @"Record":
                @"Gravar",
            @"Upload Video":
                @"Enviar vídeo",
            @"Export failed":
                @"Falha ao exportar",
            @"Recorder not found":
                @"Gravador não encontrado",
            @"Do you want to call?":
                @"Deseja fazer a chamada?",
            @"Failed to save photo":
                @"Falha ao salvar a foto",
            @"Photo saved":
                @"Foto salva",

            @"Chat":
                @"Chat",
            @"Support densor":
                @"Apoiar DeNsor",
            @"TABS":
                @"ABAS",
            @"Confirmation":
                @"Confirmação",

            @"View Photos Unlimited":
                @"Rever fotos",
            @"View 'view once' photos more than once":
                @"Reabra fotos de visualização única",

            @"View Videos Unlimited":
                @"Rever vídeos",
            @"View 'view once' videos more than once":
                @"Reabra vídeos de visualização única",

            @"Read Chats Anonymously":
                @"Ler sem confirmar leitura",
            @"Read chats without marking them as read":
                @"Sem marcar a conversa como lida",

            @"Download photos [HD]":
                @"Baixar fotos HD",
            @"Long-press to save 'view once' photos":
                @"Segure para salvar fotos únicas",

            @"Download videos":
                @"Baixar vídeos",
            @"Long-press to save 'view once' videos":
                @"Segure para salvar vídeos únicos",

            @"Loop videos":
                @"Repetir vídeos",

            @"No Screenshot Detection":
                @"Sem aviso de captura",

            @"Upload videos as voice messages":
                @"Enviar vídeo como voz",
            @"Videos will be sent as 'voice messages'":
                @"Envia como mensagem de voz",

            @"Upload photos in HD":
                @"Enviar fotos em HD",
            @"Photos will be uploaded in HD quality":
                @"Envia em qualidade HD",

            @"Watch stories anonymously":
                @"Ver stories anonimamente",
            @"Watch without marking them as seen":
                @"Sem marcar como visto",

            @"Remove Tray Stories":
                @"Ocultar stories do feed",
            @"Hides Stories Tray In Main Feed":
                @"Oculta a bandeja principal",

            @"Call Confirmation":
                @"Confirmar chamada",
            @"Show alert before calling someone":
                @"Pergunta antes de ligar",

            @"Hide Reply Bar":
                @"Ocultar barra de resposta",
            @"Hide reply bar in stoires":
                @"Oculta a resposta nos stories",

            @"Hide 'Stories' tab":
                @"Ocultar Stories",
            @"Hide 'Menu' tab":
                @"Ocultar Menu",
            @"Hide 'Notifications' tab":
                @"Ocultar Notificações",
            @"Hide 'Chats' tab":
                @"Ocultar Conversas",

            @"More by DeNsor":
                @"Mais de DeNsor",

            @"MSGPlusX [Read this]":
                @"MSGPlusX [Leia isto]",

            @"Disables the 'You took a screenshot' notification in chats":
                @"Desativa a notificação de captura de tela nas conversas",

            @"Uploading videos as voice messages works amazingly on jailbroken devices and with sideload methods, but on LiveContainer you may not be able to play the voice messages you upload. However, other people can still play them on their side.":
                @"O envio de vídeos como mensagens de voz funciona muito bem em dispositivos com jailbreak e por sideload. No LiveContainer, talvez você não consiga reproduzir as mensagens de voz enviadas, mas as outras pessoas ainda poderão reproduzi-las normalmente.",

            @"Default":
                @"Padrão"
        };
    });

    NSString *translated = map[string];

    if (translated) {
        return translated;
    }

    static NSArray<NSArray<NSString *> *> *prefixes;
    static dispatch_once_t prefixOnce;

    dispatch_once(&prefixOnce, ^{
        prefixes = @[
            @[@"New Version Available : ",
              @"Nova versão disponível: "],
            @[@"iOS Version : ",
              @"Versão do iOS: "],
            @[@"Device : ",
              @"Dispositivo: "],
            @[@"Messenger Version : ",
              @"Versão do Messenger: "],
            @[@"MSGPlusX Version : ",
              @"Versão do MSGPlusX: "],
            @[@"Bundle : ",
              @"Bundle: "],
            @[@"Status : ",
              @"Status: "]
        ];
    });

    for (NSArray<NSString *> *pair in prefixes) {
        NSString *source = pair[0];
        NSString *destination = pair[1];

        if ([string hasPrefix:source]) {
            return [
                destination stringByAppendingString:
                    [string substringFromIndex:source.length]
            ];
        }
    }

    return string;
}

typedef id (*MPLabelIMP)(
    id,
    SEL,
    id,
    id,
    id
);

typedef id (*MPSectionIMP)(
    id,
    SEL,
    id
);

typedef id (*MPSwitchIMP)(
    id,
    SEL,
    id,
    id,
    id,
    BOOL,
    SEL
);

typedef id (*MPNewButtonIMP)(
    id,
    SEL,
    id,
    id,
    SEL,
    id
);

typedef id (*MPButtonIMP)(
    id,
    SEL,
    id,
    id,
    SEL,
    id,
    id
);

static MPLabelIMP MPOrigLabel = NULL;
static MPSectionIMP MPOrigSection = NULL;
static MPSwitchIMP MPOrigSwitch = NULL;
static MPNewButtonIMP MPOrigNewButton = NULL;
static MPButtonIMP MPOrigButton = NULL;

static id MPLabelReplacement(
    id self,
    SEL _cmd,
    id title,
    id detail,
    id key
) {
    return MPOrigLabel(
        self,
        _cmd,
        MPTranslateString(title),
        MPTranslateString(detail),
        key
    );
}

static id MPSectionReplacement(
    id self,
    SEL _cmd,
    id title
) {
    return MPOrigSection(
        self,
        _cmd,
        MPTranslateString(title)
    );
}

static id MPSwitchReplacement(
    id self,
    SEL _cmd,
    id title,
    id detail,
    id key,
    BOOL defaultValue,
    SEL action
) {
    return MPOrigSwitch(
        self,
        _cmd,
        MPTranslateString(title),
        MPTranslateString(detail),
        key,
        defaultValue,
        action
    );
}

static id MPNewButtonReplacement(
    id self,
    SEL _cmd,
    id title,
    id detail,
    SEL action,
    id color
) {
    return MPOrigNewButton(
        self,
        _cmd,
        MPTranslateString(title),
        MPTranslateString(detail),
        action,
        color
    );
}

static id MPButtonReplacement(
    id self,
    SEL _cmd,
    id title,
    id detail,
    SEL action,
    id color,
    id image
) {
    return MPOrigButton(
        self,
        _cmd,
        MPTranslateString(title),
        MPTranslateString(detail),
        action,
        color,
        image
    );
}

typedef id (*MPAlertControllerIMP)(
    id,
    SEL,
    id,
    id,
    NSInteger
);

typedef id (*MPAlertActionIMP)(
    id,
    SEL,
    id,
    NSInteger,
    id
);

static MPAlertControllerIMP MPOrigAlertController = NULL;
static MPAlertActionIMP MPOrigAlertAction = NULL;

static id MPAlertControllerReplacement(
    id self,
    SEL _cmd,
    id title,
    id message,
    NSInteger style
) {
    return MPOrigAlertController(
        self,
        _cmd,
        MPTranslateString(title),
        MPTranslateString(message),
        style
    );
}

static id MPAlertActionReplacement(
    id self,
    SEL _cmd,
    id title,
    NSInteger style,
    id handler
) {
    return MPOrigAlertAction(
        self,
        _cmd,
        MPTranslateString(title),
        style,
        handler
    );
}

typedef void (*MPWordmarkLayoutIMP)(
    id,
    SEL
);

static MPWordmarkLayoutIMP MPOrigWordmarkLayout = NULL;

static void MPSetHidden(
    id object,
    BOOL hidden
) {
    if (!object ||
        ![object respondsToSelector:
            @selector(setHidden:)]) {
        return;
    }

    ((void (*)(id, SEL, BOOL))
        (void *)objc_msgSend)(
            object,
            @selector(setHidden:),
            hidden
        );
}

static void MPWordmarkLayoutReplacement(
    id self,
    SEL _cmd
) {
    if (MPOrigWordmarkLayout) {
        MPOrigWordmarkLayout(
            self,
            _cmd
        );
    }

    id customLabel =
        ((id (*)(id, SEL, NSInteger))
            (void *)objc_msgSend)(
                self,
                @selector(viewWithTag:),
                (NSInteger)0x26B7
            );

    Ivar imageIvar =
        class_getInstanceVariable(
            object_getClass(self),
            "_imageView"
        );

    id originalImageView = nil;

    if (imageIvar) {
        originalImageView =
            object_getIvar(
                self,
                imageIvar
            );
    }

    if (originalImageView) {
        MPSetHidden(
            originalImageView,
            NO
        );

        MPSetHidden(
            customLabel,
            YES
        );
    }
}

static BOOL MPMSGPlusHooksInstalled = NO;
static NSInteger MPMSGPlusProbeAttempt = 0;

static BOOL MPHookInstanceMethod(
    Class cls,
    const char *selectorName,
    IMP replacement,
    IMP *original,
    unsigned int expectedArguments
) {
    if (!cls ||
        !selectorName ||
        !replacement ||
        !original) {
        return NO;
    }

    SEL selector =
        sel_registerName(
            selectorName
        );

    Method method =
        class_getInstanceMethod(
            cls,
            selector
        );

    if (!method) {
        return NO;
    }

    if (method_getNumberOfArguments(method) !=
        expectedArguments) {
        return NO;
    }

    IMP previous =
        method_setImplementation(
            method,
            replacement
        );

    if (!previous) {
        return NO;
    }

    *original = previous;
    return YES;
}

static BOOL MPHookClassMethod(
    Class cls,
    const char *selectorName,
    IMP replacement,
    IMP *original,
    unsigned int expectedArguments
) {
    if (!cls) {
        return NO;
    }

    SEL selector =
        sel_registerName(
            selectorName
        );

    Method method =
        class_getClassMethod(
            cls,
            selector
        );

    if (!method) {
        return NO;
    }

    if (method_getNumberOfArguments(method) !=
        expectedArguments) {
        return NO;
    }

    IMP previous =
        method_setImplementation(
            method,
            replacement
        );

    if (!previous) {
        return NO;
    }

    *original = previous;
    return YES;
}

static BOOL MPTryInstallMSGPlusHooks(void) {
    if (MPMSGPlusHooksInstalled) {
        return YES;
    }

    Class settingsClass =
        objc_getClass(
            "MSGSettingsViewController"
        );

    Class wordmarkClass =
        objc_getClass(
            "MSGMessengerWordmarkView"
        );

    if (!settingsClass ||
        !wordmarkClass) {
        return NO;
    }

    BOOL ok = YES;

    if (!MPOrigLabel) {
        ok = MPHookInstanceMethod(
            settingsClass,
            "labelTitle:detailTitle:key:",
            (IMP)MPLabelReplacement,
            (IMP *)&MPOrigLabel,
            5
        ) && ok;
    }

    if (!MPOrigSection) {
        ok = MPHookInstanceMethod(
            settingsClass,
            "Section:",
            (IMP)MPSectionReplacement,
            (IMP *)&MPOrigSection,
            3
        ) && ok;
    }

    if (!MPOrigSwitch) {
        ok = MPHookInstanceMethod(
            settingsClass,
            "switchTitle:detailTitle:key:"
            "defaultValue:Action:",
            (IMP)MPSwitchReplacement,
            (IMP *)&MPOrigSwitch,
            7
        ) && ok;
    }

    if (!MPOrigNewButton) {
        ok = MPHookInstanceMethod(
            settingsClass,
            "newbutton:detailTitle:"
            "action:color:",
            (IMP)MPNewButtonReplacement,
            (IMP *)&MPOrigNewButton,
            6
        ) && ok;
    }

    if (!MPOrigButton) {
        ok = MPHookInstanceMethod(
            settingsClass,
            "button:detailTitle:"
            "action:color:image:",
            (IMP)MPButtonReplacement,
            (IMP *)&MPOrigButton,
            7
        ) && ok;
    }

    if (!MPOrigWordmarkLayout) {
        ok = MPHookInstanceMethod(
            wordmarkClass,
            "layoutSubviews",
            (IMP)MPWordmarkLayoutReplacement,
            (IMP *)&MPOrigWordmarkLayout,
            2
        ) && ok;
    }

    Class alertControllerClass =
        objc_getClass(
            "UIAlertController"
        );

    if (!MPOrigAlertController &&
        alertControllerClass) {
        MPHookClassMethod(
            alertControllerClass,
            "alertControllerWithTitle:"
            "message:preferredStyle:",
            (IMP)MPAlertControllerReplacement,
            (IMP *)&MPOrigAlertController,
            5
        );
    }

    Class alertActionClass =
        objc_getClass(
            "UIAlertAction"
        );

    if (!MPOrigAlertAction &&
        alertActionClass) {
        MPHookClassMethod(
            alertActionClass,
            "actionWithTitle:"
            "style:handler:",
            (IMP)MPAlertActionReplacement,
            (IMP *)&MPOrigAlertAction,
            5
        );
    }

    if (ok &&
        MPOrigLabel &&
        MPOrigSection &&
        MPOrigSwitch &&
        MPOrigNewButton &&
        MPOrigButton &&
        MPOrigWordmarkLayout) {
        MPMSGPlusHooksInstalled = YES;
        return YES;
    }

    return NO;
}

static void MPScheduleMSGPlusProbe(void);

static void MPMSGPlusProbe(void) {
    if (MPMSGPlusHooksInstalled) {
        return;
    }

    MPMSGPlusProbeAttempt += 1;

    if (MPTryInstallMSGPlusHooks()) {
        return;
    }

    if (MPMSGPlusProbeAttempt < 400) {
        MPScheduleMSGPlusProbe();
    }
}

static void MPScheduleMSGPlusProbe(void) {
    NSTimeInterval delay =
        MPMSGPlusProbeAttempt < 100
            ? 0.025
            : 0.100;

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(
                delay * NSEC_PER_SEC
            )
        ),
        dispatch_get_global_queue(
            QOS_CLASS_USER_INITIATED,
            0
        ),
        ^{
            MPMSGPlusProbe();
        }
    );
}

__attribute__((constructor))
static void MessengerEnhancementsInit(void) {
    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(
                0.100 * NSEC_PER_SEC
            )
        ),
        dispatch_get_global_queue(
            QOS_CLASS_USER_INITIATED,
            0
        ),
        ^{
            if (!MPTryInstallMSGPlusHooks()) {
                MPScheduleMSGPlusProbe();
            }
        }
    );
}
