#import <XCTest/XCTest.h>

/// Long press selects a word and shows its lookup card on every page, not just a chapter's first: pages once shared one
/// layout manager, and UIKit lets only the text view showing its first container be selected. Like the toolbars, an
/// open card masks the page: a tap at the edge only closes it and doesn't turn.
@interface SelectionUITests : XCTestCase
@end

@implementation SelectionUITests {
    XCUIApplication *_app;
}

- (void)setUp {
    self.continueAfterFailure = NO;
}

- (void)testCurl { [self selectAcrossPagesWithTurn:@"curl"]; }
- (void)testSlide { [self selectAcrossPagesWithTurn:@"slide"]; }
- (void)testCover { [self selectAcrossPagesWithTurn:@"cover"]; }
- (void)testScroll { [self selectAcrossPagesWithTurn:@"scroll"]; }

- (void)selectAcrossPagesWithTurn:(NSString *)turn {
    _app = [[XCUIApplication alloc] init];
    _app.launchArguments = @[@"-freshLibrary", @"-readerPageTurn", turn, @"-readerFont", @"30", @"-readerTipSeen", @"YES"];
    [_app launch];
    [[_app.buttons matchingPredicate:[NSPredicate predicateWithFormat:@"identifier BEGINSWITH 'book-'"]].firstMatch tap];
    [_app.buttons[@"open-chapters"] tap];
    [[_app.collectionViews.cells elementBoundByIndex:1] tap];
    [[self at:0.5 y:0.5] tap]; // Puts the toolbars away.
    [NSThread sleepForTimeInterval:1];

    [self lookUp:@"on the first page"];
    BOOL paged = ![turn isEqualToString:@"scroll"];
    if (paged) {
        NSString *page = [self shownPage];
        [self lookUp:@"before tapping the edge" closingAt:[self at:0.95 y:0.5]];
        XCTAssertEqualObjects([self shownPage], page, @"an edge tap that closed the card also turned the page");
        [[self at:0.95 y:0.5] tap];
        [self lookUp:@"after tapping to the next page"];
        [[self at:0.8 y:0.5] pressForDuration:0.05 thenDragToCoordinate:[self at:0.15 y:0.5]];
        [self lookUp:@"after swiping to the next page"];
    } else {
        [_app.textViews[@"reading-text"] swipeUp];
        [self lookUp:@"after scrolling on"];
    }
}

/// Long presses a word, expects its card, then taps the selection away and expects the card gone.
- (void)lookUp:(NSString *)when {
    [self lookUp:when closingAt:[self at:0.4 y:0.4]];
}

- (void)lookUp:(NSString *)when closingAt:(XCUICoordinate *)closing {
    [NSThread sleepForTimeInterval:1];
    XCUIElement *card = [_app descendantsMatchingType:XCUIElementTypeAny][@"lookup-card"];
    // Above the middle, where a card hanging below the word leaves the press point clear.
    [[self at:0.4 y:0.4] pressForDuration:1.0];
    XCTAssertTrue([card waitForExistenceWithTimeout:3], @"long press showed no lookup card %@", when);
    [closing tap];
    NSPredicate *gone = [NSPredicate predicateWithFormat:@"exists == NO"];
    [self waitForExpectations:@[[self expectationForPredicate:gone evaluatedWithObject:card handler:nil]] timeout:3];
    [NSThread sleepForTimeInterval:1]; // A turn the tap set off would have landed by now.
}

/// The identifier of the one page on screen; neighbours are laid out off it.
- (NSString *)shownPage {
    CGRect screen = _app.windows.firstMatch.frame;
    NSPredicate *pages = [NSPredicate predicateWithFormat:@"identifier BEGINSWITH 'page '"];
    NSMutableArray<NSString *> *shown = [NSMutableArray array];
    for (XCUIElement *page in [[_app descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:pages].allElementsBoundByIndex) {
        CGRect frame = page.frame;
        if (CGRectContainsPoint(screen, CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame)))) [shown addObject:page.identifier];
    }
    XCTAssertEqual(shown.count, 1, @"expected one page on screen, saw %@", shown);
    return shown.firstObject;
}

- (XCUICoordinate *)at:(CGFloat)x y:(CGFloat)y {
    return [_app.windows.firstMatch coordinateWithNormalizedOffset:CGVectorMake(x, y)];
}
@end
