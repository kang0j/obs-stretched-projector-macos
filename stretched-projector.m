/*
 * OBS Stretched Projector for macOS
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Opens projector windows that stretch the Program output (or a scene)
 * to fill the whole window/display, ignoring the canvas aspect ratio.
 *
 * Inspired by Wst-04d12/obs-stretched-projector (Windows), which patches
 * OBSProjector::OBSRender in memory. This is an independent implementation
 * that only uses the public libobs / obs-frontend-api C API and plain Cocoa
 * windows, so it does not depend on OBS' internal code layout or Qt ABI.
 */

#import <Cocoa/Cocoa.h>

#include <obs-module.h>
#include <obs-frontend-api.h>

OBS_DECLARE_MODULE()

#define PLUGIN_NAME "Stretched Projector"
#define SP_LOG(level, fmt, ...) blog(level, "[stretched-projector] " fmt, ##__VA_ARGS__)

static const CGDirectDisplayID kWindowedDisplay = 0;

/* ------------------------------------------------------------------------- */
/* Render side (runs on the OBS graphics thread)                             */

struct sp_render {
	obs_weak_source_t *weak_source; /* NULL = Program output */
	volatile bool stretch;
};

static void sp_draw(void *data, uint32_t cx, uint32_t cy)
{
	struct sp_render *render = data;
	obs_source_t *source = NULL;
	uint32_t base_cx, base_cy;

	if (render->weak_source) {
		source = obs_weak_source_get_source(render->weak_source);
		if (!source)
			return;
		base_cx = obs_source_get_width(source);
		base_cy = obs_source_get_height(source);
	} else {
		struct obs_video_info ovi;
		if (!obs_get_video_info(&ovi))
			return;
		base_cx = ovi.base_width;
		base_cy = ovi.base_height;
	}

	if (!base_cx || !base_cy || !cx || !cy)
		goto done;

	int x = 0, y = 0, view_cx = (int)cx, view_cy = (int)cy;

	if (!render->stretch) {
		/* Same letterboxing the stock OBS projector does */
		double scale = fmin((double)cx / base_cx, (double)cy / base_cy);
		view_cx = (int)(scale * base_cx);
		view_cy = (int)(scale * base_cy);
		x = ((int)cx - view_cx) / 2;
		y = ((int)cy - view_cy) / 2;
	}

	gs_viewport_push();
	gs_projection_push();
	gs_ortho(0.0f, (float)base_cx, 0.0f, (float)base_cy, -100.0f, 100.0f);
	gs_set_viewport(x, y, view_cx, view_cy);

	if (source)
		obs_source_video_render(source);
	else
		obs_render_main_texture();

	gs_projection_pop();
	gs_viewport_pop();

done:
	obs_source_release(source);
}

/* ------------------------------------------------------------------------- */
/* Window side (main thread)                                                  */

@class SPProjector;

static NSMutableArray<SPProjector *> *g_projectors;

static CGDirectDisplayID sp_screen_id(NSScreen *screen)
{
	return [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
}

static NSScreen *sp_screen_for_id(CGDirectDisplayID displayID)
{
	for (NSScreen *screen in NSScreen.screens) {
		if (sp_screen_id(screen) == displayID)
			return screen;
	}
	return nil;
}

@interface SPBorderlessWindow : NSWindow
@end

@implementation SPBorderlessWindow
- (BOOL)canBecomeKeyWindow
{
	return YES;
}
- (BOOL)canBecomeMainWindow
{
	return YES;
}
@end

@interface SPView : NSView
@property (nonatomic, weak) SPProjector *owner;
@end

@interface SPProjector : NSObject <NSWindowDelegate>
@property (nonatomic, readonly) CGDirectDisplayID displayID;
- (instancetype)initWithSourceName:(NSString *)sourceName displayID:(CGDirectDisplayID)displayID;
- (void)close;
- (void)resizeDisplay;
- (NSMenu *)contextMenu;
@end

@implementation SPView

- (BOOL)acceptsFirstResponder
{
	return YES;
}

- (BOOL)isOpaque
{
	return YES;
}

- (void)keyDown:(NSEvent *)event
{
	if (event.keyCode == 53 /* Escape */)
		[self.owner close];
	else
		[super keyDown:event];
}

- (NSMenu *)menuForEvent:(NSEvent *)event
{
	return [self.owner contextMenu];
}

- (void)setFrameSize:(NSSize)newSize
{
	[super setFrameSize:newSize];
	[self.owner resizeDisplay];
}

- (void)viewDidChangeBackingProperties
{
	[super viewDidChangeBackingProperties];
	[self.owner resizeDisplay];
}

- (void)resetCursorRects
{
	if (self.owner.displayID == kWindowedDisplay)
		return;

	static NSCursor *blank;
	if (!blank)
		blank = [[NSCursor alloc] initWithImage:[[NSImage alloc] initWithSize:NSMakeSize(1, 1)]
						hotSpot:NSZeroPoint];
	[self addCursorRect:self.bounds cursor:blank];
}

@end

static void sp_source_removed(void *data, calldata_t *cd)
{
	(void)cd;
	SPProjector *projector = (__bridge SPProjector *)data;
	dispatch_async(dispatch_get_main_queue(), ^{
		[projector close];
	});
}

@implementation SPProjector {
	NSWindow *_window;
	SPView *_view;
	obs_display_t *_display;
	struct sp_render _render;
	obs_source_t *_signalSource; /* strong ref while the remove signal is connected */
	BOOL _closed;
}

- (instancetype)initWithSourceName:(NSString *)sourceName displayID:(CGDirectDisplayID)displayID
{
	if (!(self = [super init]))
		return nil;

	_displayID = displayID;
	_render.stretch = true;

	NSString *title = @"Program";

	if (sourceName) {
		obs_source_t *source = obs_get_source_by_name(sourceName.UTF8String);
		if (!source) {
			SP_LOG(LOG_WARNING, "Source '%s' not found", sourceName.UTF8String);
			return nil;
		}
		_render.weak_source = obs_source_get_weak_source(source);
		obs_source_inc_showing(source);

		signal_handler_connect(obs_source_get_signal_handler(source), "remove", sp_source_removed,
				       (__bridge void *)self);
		_signalSource = source; /* keep the reference until close */
		title = sourceName;
	}

	NSScreen *screen = displayID == kWindowedDisplay ? nil : sp_screen_for_id(displayID);

	if (screen) {
		_window = [[SPBorderlessWindow alloc] initWithContentRect:screen.frame
								 styleMask:NSWindowStyleMaskBorderless
								   backing:NSBackingStoreBuffered
								     defer:NO];
		_window.level = NSMainMenuWindowLevel + 1;
		_window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
					     NSWindowCollectionBehaviorStationary |
					     NSWindowCollectionBehaviorFullScreenAuxiliary |
					     NSWindowCollectionBehaviorIgnoresCycle;
		[_window setFrame:screen.frame display:NO];
	} else {
		_displayID = kWindowedDisplay;
		_window = [[NSWindow alloc]
			initWithContentRect:NSMakeRect(0, 0, 960, 540)
				  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
					    NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
				    backing:NSBackingStoreBuffered
				      defer:NO];
		[_window center];
		_window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
	}

	_window.title = [NSString stringWithFormat:@"Stretched Projector - %@", title];
	_window.releasedWhenClosed = NO;
	_window.backgroundColor = NSColor.blackColor;
	_window.delegate = self;

	_view = [[SPView alloc] initWithFrame:_window.contentView.bounds];
	_view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	_view.owner = self;
	_window.contentView = _view;

	[_window makeKeyAndOrderFront:nil];
	[_window makeFirstResponder:_view];

	NSSize px = [_view convertRectToBacking:_view.bounds].size;

	struct gs_init_data info = {0};
	info.cx = (uint32_t)px.width;
	info.cy = (uint32_t)px.height;
	info.format = GS_BGRA;
	info.zsformat = GS_ZS_NONE;
	info.window.view = _view;

	_display = obs_display_create(&info, 0x000000);
	if (!_display) {
		SP_LOG(LOG_ERROR, "obs_display_create failed");
		[self close];
		return nil;
	}

	obs_display_add_draw_callback(_display, sp_draw, &_render);

	SP_LOG(LOG_INFO, "Opened projector '%s' (%s, %ux%u px)", title.UTF8String,
	       screen ? "fullscreen" : "windowed", info.cx, info.cy);

	return self;
}

- (void)resizeDisplay
{
	if (!_display || _closed)
		return;

	NSSize px = [_view convertRectToBacking:_view.bounds].size;
	if (px.width >= 1 && px.height >= 1)
		obs_display_resize(_display, (uint32_t)px.width, (uint32_t)px.height);
}

- (void)close
{
	if (_closed)
		return;
	_closed = YES;

	if (_display) {
		obs_display_remove_draw_callback(_display, sp_draw, &_render);
		obs_display_destroy(_display);
		_display = NULL;
	}

	if (_signalSource) {
		signal_handler_disconnect(obs_source_get_signal_handler(_signalSource), "remove",
					  sp_source_removed, (__bridge void *)self);
		obs_source_dec_showing(_signalSource);
		obs_source_release(_signalSource);
		_signalSource = NULL;
	}

	obs_weak_source_release(_render.weak_source);
	_render.weak_source = NULL;

	_window.delegate = nil;
	[_window orderOut:nil];
	[_window close];

	[g_projectors removeObject:self];
}

- (void)windowWillClose:(NSNotification *)notification
{
	(void)notification;
	[self close];
}

- (void)windowDidChangeScreen:(NSNotification *)notification
{
	(void)notification;
	[self resizeDisplay];
}

- (void)toggleStretch:(id)sender
{
	(void)sender;
	_render.stretch = !_render.stretch;
}

- (void)toggleAlwaysOnTop:(id)sender
{
	(void)sender;
	_window.level = _window.level == NSFloatingWindowLevel ? NSNormalWindowLevel : NSFloatingWindowLevel;
}

- (void)closeFromMenu:(id)sender
{
	(void)sender;
	[self close];
}

- (NSMenu *)contextMenu
{
	NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
	menu.autoenablesItems = NO;

	NSMenuItem *item = [menu addItemWithTitle:@"Stretch to Fill"
					   action:@selector(toggleStretch:)
				    keyEquivalent:@""];
	item.target = self;
	item.state = _render.stretch ? NSControlStateValueOn : NSControlStateValueOff;

	if (_displayID == kWindowedDisplay) {
		item = [menu addItemWithTitle:@"Always on Top"
				       action:@selector(toggleAlwaysOnTop:)
				keyEquivalent:@""];
		item.target = self;
		item.state = _window.level == NSFloatingWindowLevel ? NSControlStateValueOn
								      : NSControlStateValueOff;
	}

	[menu addItem:NSMenuItem.separatorItem];

	item = [menu addItemWithTitle:@"Close Projector" action:@selector(closeFromMenu:) keyEquivalent:@""];
	item.target = self;

	return menu;
}

@end

/* ------------------------------------------------------------------------- */
/* Tools menu                                                                 */

@interface SPMenuController : NSObject
@end

@implementation SPMenuController

- (void)openProjector:(NSMenuItem *)item
{
	NSDictionary *target = item.representedObject;
	id name = target[@"source"];
	CGDirectDisplayID displayID = [target[@"display"] unsignedIntValue];

	/* Only one fullscreen projector per display */
	if (displayID != kWindowedDisplay) {
		for (SPProjector *p in [g_projectors copy]) {
			if (p.displayID == displayID)
				[p close];
		}
	}

	SPProjector *projector = [[SPProjector alloc] initWithSourceName:(name == NSNull.null ? nil : name)
							       displayID:displayID];
	if (projector)
		[g_projectors addObject:projector];
}

- (void)closeAll:(id)sender
{
	(void)sender;
	for (SPProjector *p in [g_projectors copy])
		[p close];
}

- (NSMenu *)targetMenuForSource:(NSString *)sourceName
{
	NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
	menu.autoenablesItems = NO;
	id source = sourceName ?: NSNull.null;

	NSArray<NSScreen *> *screens = NSScreen.screens;
	for (NSUInteger i = 0; i < screens.count; i++) {
		NSScreen *screen = screens[i];
		NSSize px = [screen convertRectToBacking:screen.frame].size;
		NSString *title = [NSString stringWithFormat:@"Fullscreen: %@ (%.0fx%.0f)", screen.localizedName,
							     px.width, px.height];

		NSMenuItem *item = [menu addItemWithTitle:title
						   action:@selector(openProjector:)
					    keyEquivalent:@""];
		item.target = self;
		item.representedObject = @{@"source": source, @"display": @(sp_screen_id(screen))};
	}

	[menu addItem:NSMenuItem.separatorItem];

	NSMenuItem *item = [menu addItemWithTitle:@"Windowed" action:@selector(openProjector:) keyEquivalent:@""];
	item.target = self;
	item.representedObject = @{@"source": source, @"display": @(kWindowedDisplay)};

	return menu;
}

- (void)showMenu
{
	NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
	menu.autoenablesItems = NO;

	NSMenuItem *program = [menu addItemWithTitle:@"Program" action:nil keyEquivalent:@""];
	program.submenu = [self targetMenuForSource:nil];

	NSMenuItem *scenes = [menu addItemWithTitle:@"Scene" action:nil keyEquivalent:@""];
	NSMenu *sceneMenu = [[NSMenu alloc] initWithTitle:@""];
	sceneMenu.autoenablesItems = NO;

	struct obs_frontend_source_list list = {0};
	obs_frontend_get_scenes(&list);
	for (size_t i = 0; i < list.sources.num; i++) {
		const char *name = obs_source_get_name(list.sources.array[i]);
		if (!name)
			continue;
		NSString *sceneName = @(name);
		NSMenuItem *sceneItem = [sceneMenu addItemWithTitle:sceneName action:nil keyEquivalent:@""];
		sceneItem.submenu = [self targetMenuForSource:sceneName];
	}
	obs_frontend_source_list_free(&list);

	scenes.submenu = sceneMenu;
	scenes.enabled = sceneMenu.numberOfItems > 0;

	[menu addItem:NSMenuItem.separatorItem];

	NSMenuItem *closeAll = [menu addItemWithTitle:@"Close All Stretched Projectors"
					       action:@selector(closeAll:)
					keyEquivalent:@""];
	closeAll.target = self;
	closeAll.enabled = g_projectors.count > 0;

	[menu popUpMenuPositioningItem:nil atLocation:NSEvent.mouseLocation inView:nil];
}

- (void)screensChanged:(NSNotification *)notification
{
	(void)notification;
	for (SPProjector *p in [g_projectors copy]) {
		if (p.displayID != kWindowedDisplay && !sp_screen_for_id(p.displayID))
			[p close];
	}
}

@end

static SPMenuController *g_menu;

static void sp_tools_menu_clicked(void *data)
{
	(void)data;
	/* Let Qt finish handling its menu before showing ours */
	dispatch_async(dispatch_get_main_queue(), ^{
		[g_menu showMenu];
	});
}

static void sp_close_all(void)
{
	for (SPProjector *p in [g_projectors copy])
		[p close];
}

static void sp_frontend_event(enum obs_frontend_event event, void *data)
{
	(void)data;
	if (event == OBS_FRONTEND_EVENT_EXIT)
		sp_close_all();
}

bool obs_module_load(void)
{
	g_projectors = [NSMutableArray array];
	g_menu = [[SPMenuController alloc] init];

	[NSNotificationCenter.defaultCenter addObserver:g_menu
					       selector:@selector(screensChanged:)
						   name:NSApplicationDidChangeScreenParametersNotification
						 object:nil];

	obs_frontend_add_tools_menu_item(PLUGIN_NAME, sp_tools_menu_clicked, NULL);
	obs_frontend_add_event_callback(sp_frontend_event, NULL);

	SP_LOG(LOG_INFO, "loaded");
	return true;
}

void obs_module_unload(void)
{
	obs_frontend_remove_event_callback(sp_frontend_event, NULL);
	sp_close_all();
	[NSNotificationCenter.defaultCenter removeObserver:g_menu];
	g_menu = nil;
	g_projectors = nil;
}

const char *obs_module_name(void)
{
	return PLUGIN_NAME;
}

const char *obs_module_description(void)
{
	return "Projectors that stretch the output to fill the entire display, ignoring the canvas aspect ratio.";
}
