#import "MWMOpeningHoursSection.h"
#import <CoreApi/MWMOpeningHoursCommon.h>
#import "MWMOpeningHoursTableViewCell.h"
#import "SwiftBridge.h"

extern NSDictionary * const kMWMOpeningHoursEditorTableCells;

extern UITableViewRowAnimation const kMWMOpeningHoursEditorRowAnimation;

@interface MWMOpeningHoursSection ()

@property(nonatomic, readonly) NSUInteger excludeTimeCount;

@property(nonatomic) BOOL skipStoreCachedData;

@property(nonatomic) BOOL removeBrokenExcludeTime;

@end

using namespace editor::ui;
using namespace osmoh;

@implementation MWMOpeningHoursSection

- (instancetype _Nonnull)initWithDelegate:(id<MWMOpeningHoursSectionProtocol> _Nonnull)delegate
{
  self = [super init];
  if (self)
  {
    _delegate = delegate;
    _selectedRow = nil;
  }
  return self;
}

- (void)refreshIndex:(NSUInteger)index
{
  _index = index;
}

#pragma mark - Rows

- (NSUInteger)firstRowForKey:(MWMOpeningHoursEditorCells)key
{
  NSUInteger const numberOfRows = self.numberOfRows;
  for (NSUInteger row = 0; row != numberOfRows; ++row)
    if ([self cellKeyForRow:row] == key)
      return row;
  return numberOfRows;
}

- (MWMOpeningHoursEditorCells)cellKeyForRow:(NSUInteger)row
{
  if (row == 0)
    return MWMOpeningHoursEditorDaysSelectorCell;
  if (row == 1)
    return MWMOpeningHoursEditorAllDayCell;

  NSUInteger const numberOfRows = self.numberOfRows;
  BOOL const firstSection = (self.index == 0);

  if (firstSection && row == numberOfRows - 1)
    return MWMOpeningHoursEditorAddClosedCell;
  else if (!firstSection && row == numberOfRows - 1)
    return MWMOpeningHoursEditorDeleteScheduleCell;
  else if (!firstSection && row == numberOfRows - 2)
    return MWMOpeningHoursEditorAddClosedCell;
  else if (row == 2)
    return MWMOpeningHoursEditorTimeSpanCell;

  if ([self.selectedRow isEqualToNumber:@(row - 1)])
    return MWMOpeningHoursEditorTimeSelectorCell;

  return MWMOpeningHoursEditorClosedSpanCell;
}

- (NSUInteger)numberOfRowsForAllDay:(BOOL)allDay
{
  NSUInteger rowsCount = 2;  // MWMOpeningHoursDaysSelectorTableViewCell, MWMOpeningHoursAllDayTableViewCell
  if (!allDay)
  {
    rowsCount += 2;  // MWMOpeningHoursTimeSpanTableViewCell, MWMOpeningHoursAddClosedTableViewCell
    rowsCount += [self closedTimesCount];  // MWMOpeningHoursClosedSpanTableViewCell
    if (self.selectedRow)
      rowsCount++;  // MWMOpeningHoursTimeSelectorTableViewCell
  }
  if (self.index != 0)
    rowsCount++;  // MWMOpeningHoursDeleteScheduleTableViewCell
  return rowsCount;
}

- (CGFloat)heightForRow:(NSUInteger)row withWidth:(CGFloat)width
{
  Class cls = kMWMOpeningHoursEditorTableCells[@([self cellKeyForRow:row])];
  return [cls heightForWidth:width];
}

- (void)fillCell:(MWMOpeningHoursTableViewCell * _Nonnull)cell
{
  cell.section = self;
}

#pragma mark - Row time

- (NSDateComponents * _Nonnull)timeForRow:(NSUInteger)row isStart:(BOOL)isStart
{
  NSDateComponents * cachedTime = isStart ? self.cachedStartTime : self.cachedEndTime;
  if (cachedTime && [self isRowSelected:row])
    return cachedTime;

  BOOL const isClosed = [self cellKeyForRow:row] != MWMOpeningHoursEditorTimeSpanCell;
  auto tt = [self timeTableProxy];
  NSUInteger const index = isClosed ? [self closedTimeIndex:row] : 0;

  // Defensive bounds check: the table view may display stale rows during
  // navigation transitions if the data model was modified without a full reload.
  if (isClosed && index >= tt.GetExcludeTime().size())
  {
    NSDateComponents * dc = [[NSDateComponents alloc] init];
    dc.hour = 0;
    dc.minute = 0;
    return dc;
  }

  Timespan span = isClosed ? tt.GetExcludeTime()[index] : tt.GetOpeningTime();
  return dateComponentsFromTime(isStart ? span.GetStart() : span.GetEnd());
}

- (void)setStartTime:(NSDateComponents *)startTime endTime:(NSDateComponents *)endTime isClosed:(BOOL)isClosed
{
  if (!startTime && !endTime)
    return;

  auto tt = [self timeTableProxy];
  NSUInteger const row = self.selectedRow.unsignedIntegerValue;
  NSUInteger const index = isClosed ? [self closedTimeIndex:row] : 0;

  if (isClosed && index >= tt.GetExcludeTime().size())
    return;

  Timespan span = isClosed ? tt.GetExcludeTime()[index] : tt.GetOpeningTime();

  if (startTime)
  {
    HourMinutes startHM;
    startHM.SetHours(HourMinutes::THours(startTime.hour));
    startHM.SetMinutes(HourMinutes::TMinutes(startTime.minute));
    span.SetStart(startHM);
  }
  if (endTime)
  {
    HourMinutes endHM;
    endHM.SetHours(HourMinutes::THours(endTime.hour));
    endHM.SetMinutes(HourMinutes::TMinutes(endTime.minute));
    span.SetEnd(endHM);
  }

  if (isClosed)
  {
    if (!tt.ReplaceExcludeTime(span, index) && self.removeBrokenExcludeTime)
      tt.RemoveExcludeTime(index);
  }
  else
  {
    tt.SetOpeningTime(span);
  }
  tt.Commit();
  // Note: callers are responsible for table updates after data mutation.
}

#pragma mark - Closed Time

- (NSUInteger)closedTimesCount
{
  return [self timeTableProxy].GetExcludeTime().size();
}

- (NSUInteger)closedTimeIndex:(NSUInteger)row
{
  NSUInteger indexShift = [self firstRowForKey:MWMOpeningHoursEditorTimeSpanCell] + 1;
  if (self.selectedRow && self.selectedRow.unsignedIntegerValue + 1 < row)
    indexShift++;
  NSAssert(row >= indexShift, @"Invalid row index");
  NSAssert(row - indexShift < [self closedTimesCount], @"Invalid row index");
  return row - indexShift;
}

- (void)addClosedTime
{
  self.removeBrokenExcludeTime = YES;
  // Deselect current row via setter (runs its own batch update, not nested).
  self.selectedRow = nil;

  NSUInteger const row = [self firstRowForKey:MWMOpeningHoursEditorAddClosedCell];

  auto timeTable = [self timeTableProxy];

  NSUInteger const closedTimesCountBeforeUpdate = [self closedTimesCount];

  Timespan timeSpan = timeTable.GetPredefinedExcludeTime();
  timeTable.AddExcludeTime(timeSpan);
  timeTable.Commit();

  NSUInteger const closedTimesCountAfterUpdate = [self closedTimesCount];
  if (closedTimesCountAfterUpdate < closedTimesCountBeforeUpdate)
  {
    [self refresh:YES];
    return;
  }

  if (closedTimesCountAfterUpdate > closedTimesCountBeforeUpdate)
  {
    // Deselect other sections before our batch update to avoid nesting.
    [self.delegate updateActiveSection:self.index];

    [self.delegate.tableView update:^{
      [self insertRow:row];
      // Set selection directly (not via setter) and insert selector row
      // in the same batch to avoid nested performBatchUpdates.
      self->_selectedRow = @(row);
      [self insertRow:row + 1];
    }];
  }
  [self refresh:NO];
}

- (void)removeClosedTime:(NSUInteger)row
{
  BOOL const wasSelected = [self isRowSelected:row];
  self.skipStoreCachedData = wasSelected;

  // Compute the exclude time index while the state is still consistent.
  NSUInteger const index = [self closedTimeIndex:row];

  // Store cached data for the currently selected row (if it's not the one being removed).
  // This is a pure data mutation (no table updates).
  [self storeCachedData];

  // Remove the exclude time (data mutation, outside any batch update).
  auto timeTable = [self timeTableProxy];
  timeTable.RemoveExcludeTime(index);
  timeTable.Commit();

  // Clear selection state directly to avoid nested performBatchUpdates.
  _selectedRow = nil;

  // Full reload to synchronize the table with the updated data model.
  // This avoids complex index arithmetic after data mutations that can
  // shift exclude time indices (e.g. FixTimeSpans merging spans).
  [self refresh:YES];
}

#pragma mark - Selected days

- (void)addSelectedDay:(Weekday)day
{
  auto timeTable = [self timeTableProxy];
  auto openingDays(timeTable.GetOpeningDays());
  openingDays.insert(day);
  timeTable.SetOpeningDays(openingDays);
  timeTable.Commit();
  [self refresh:YES];
}

- (void)removeSelectedDay:(Weekday)day
{
  auto timeTable = [self timeTableProxy];
  auto openingDays(timeTable.GetOpeningDays());
  openingDays.erase(day);
  timeTable.SetOpeningDays(openingDays);
  timeTable.Commit();
  [self refresh:YES];
}

- (BOOL)containsSelectedDay:(Weekday)day
{
  auto timeTable = [self timeTableProxy];
  auto const & openingDays = timeTable.GetOpeningDays();
  return openingDays.find(day) != openingDays.end();
}

#pragma mark - Table

- (void)refresh:(BOOL)force
{
  UITableView * tableView = self.delegate.tableView;
  if (force)
  {
    [tableView reloadData];
    return;
  }
  for (MWMOpeningHoursTableViewCell * cell in tableView.visibleCells)
    [cell refresh];
}

- (void)refreshForNewRowCount:(NSUInteger)newRowCount oldRowCount:(NSUInteger)oldRowCount
{
  NSAssert(newRowCount != oldRowCount, @"Invalid rows change");
  BOOL const addRows = newRowCount > oldRowCount;
  NSUInteger const minRows = MIN(newRowCount, oldRowCount);
  NSUInteger const maxRows = MAX(newRowCount, oldRowCount);
  NSMutableArray<NSIndexPath *> * indexes = [NSMutableArray arrayWithCapacity:maxRows - minRows];

  UITableView * tableView = self.delegate.tableView;
  [tableView update:^{
    for (NSUInteger row = minRows; row < maxRows; ++row)
      [indexes addObject:[NSIndexPath indexPathForRow:row inSection:self.index]];

    if (addRows)
      [tableView insertRowsAtIndexPaths:indexes withRowAnimation:kMWMOpeningHoursEditorRowAnimation];
    else
      [tableView deleteRowsAtIndexPaths:indexes withRowAnimation:kMWMOpeningHoursEditorRowAnimation];
  }];
  [self refresh:NO];
}

- (void)insertRow:(NSUInteger)row
{
  NSIndexPath * path = [NSIndexPath indexPathForRow:row inSection:self.index];
  UITableView * tableView = self.delegate.tableView;
  [tableView insertRowsAtIndexPaths:@[path] withRowAnimation:kMWMOpeningHoursEditorRowAnimation];
}

- (void)deleteRow:(NSUInteger)row
{
  NSIndexPath * path = [NSIndexPath indexPathForRow:row inSection:self.index];
  UITableView * tableView = self.delegate.tableView;
  [tableView deleteRowsAtIndexPaths:@[path] withRowAnimation:kMWMOpeningHoursEditorRowAnimation];
}

#pragma mark - Model

- (TimeTableSet::Proxy)timeTableProxy
{
  return [self.delegate timeTableProxy:self.index];
}

- (void)deleteSchedule
{
  [self.delegate deleteSchedule:self.index];
}

#pragma mark - Selected row

- (void)setSelectedRow:(NSNumber *)selectedRow
{
  if ((!_selectedRow && !selectedRow) || _selectedRow.unsignedIntegerValue == selectedRow.unsignedIntegerValue)
    return;
  NSUInteger const closedTimesCountBeforeUpdate = [self closedTimesCount];
  // storeCachedData is a pure data mutation (no table refresh calls).
  [self storeCachedData];
  if (closedTimesCountBeforeUpdate != [self closedTimesCount])
  {
    _selectedRow = nil;
    [self refresh:YES];
    return;
  }

  NSNumber * oldSelectedRow = _selectedRow;
  NSUInteger const newInd = selectedRow.unsignedIntegerValue;
  NSUInteger const oldInd = oldSelectedRow.unsignedIntegerValue;

  id<MWMOpeningHoursSectionProtocol> delegate = self.delegate;
  UITableView * tableView = delegate.tableView;

  // Deselect other sections BEFORE our batch update to avoid
  // nested performBatchUpdates (which can cause data/UI inconsistency).
  if (!oldSelectedRow && selectedRow)
    [delegate updateActiveSection:self.index];

  [tableView update:^{
    if (!oldSelectedRow)
    {
      self->_selectedRow = selectedRow;
      [self insertRow:newInd + 1];
    }
    else if (selectedRow)
    {
      if (newInd < oldInd)
      {
        self->_selectedRow = selectedRow;
        [self insertRow:newInd + 1];
      }
      else
      {
        self->_selectedRow = @(newInd - 1);
        [self insertRow:newInd];
      }

      [self deleteRow:oldInd + 1];
    }
    else
    {
      self->_selectedRow = selectedRow;
      [self deleteRow:oldInd + 1];
    }
  }];
  [self scrollToSelection];
}

- (BOOL)isRowSelected:(NSUInteger)row
{
  return self.selectedRow && self.selectedRow.unsignedIntegerValue == row;
}

- (void)storeCachedData
{
  if (!self.selectedRow)
    return;
  if (!self.skipStoreCachedData)
  {
    switch ([self cellKeyForRow:self.selectedRow.unsignedIntegerValue])
    {
    case MWMOpeningHoursEditorTimeSpanCell:
      [self setStartTime:self.cachedStartTime endTime:self.cachedEndTime isClosed:NO];
      break;
    case MWMOpeningHoursEditorClosedSpanCell:
      [self setStartTime:self.cachedStartTime endTime:self.cachedEndTime isClosed:YES];
      break;
    default: NSAssert(false, @"Invalid case"); break;
    }
  }
  self.cachedStartTime = nil;
  self.cachedEndTime = nil;
  self.skipStoreCachedData = NO;
  self.removeBrokenExcludeTime = NO;
}

#pragma mark - Scrolling

- (void)scrollIntoView
{
  dispatch_async(dispatch_get_main_queue(), ^{
    UITableView * tableView = self.delegate.tableView;
    NSUInteger const lastRow = self.numberOfRows - 1;
    NSIndexPath * path = [NSIndexPath indexPathForRow:lastRow inSection:self.index];
    [tableView scrollToRowAtIndexPath:path atScrollPosition:UITableViewScrollPositionNone animated:YES];
  });
}

- (void)scrollToSelection
{
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!self.selectedRow)
      return;
    UITableView * tableView = self.delegate.tableView;
    NSUInteger const timeSelectorRow = self.selectedRow.unsignedIntegerValue + 1;
    NSIndexPath * path = [NSIndexPath indexPathForRow:timeSelectorRow inSection:self.index];
    [tableView scrollToRowAtIndexPath:path atScrollPosition:UITableViewScrollPositionNone animated:YES];
  });
}

#pragma mark - Properties

- (BOOL)allDay
{
  return [self timeTableProxy].IsTwentyFourHours();
}

- (void)setAllDay:(BOOL)allDay
{
  BOOL const currentAllDay = self.allDay;
  if (currentAllDay == allDay)
    return;
  self.selectedRow = nil;
  NSUInteger const deleteScheduleCellShift = self.index != 0 ? 1 : 0;
  NSUInteger const oldRowCount = [self numberOfRowsForAllDay:currentAllDay] - deleteScheduleCellShift;
  NSUInteger const newRowCount = [self numberOfRowsForAllDay:allDay] - deleteScheduleCellShift;
  auto timeTable = [self timeTableProxy];
  timeTable.SetTwentyFourHours(allDay);
  timeTable.Commit();
  [self refreshForNewRowCount:newRowCount oldRowCount:oldRowCount];
  [self scrollIntoView];
}

- (NSUInteger)numberOfRows
{
  return [self numberOfRowsForAllDay:self.allDay];
}

- (void)setCachedStartTime:(NSDateComponents *)cachedStartTime
{
  _cachedStartTime = cachedStartTime;
  if (cachedStartTime)
    [self refresh:NO];
}

- (void)setCachedEndTime:(NSDateComponents *)cachedEndTime
{
  _cachedEndTime = cachedEndTime;
  if (cachedEndTime)
    [self refresh:NO];
}

- (BOOL)canAddClosedTime
{
  return [self timeTableProxy].CanAddExcludeTime();
}

@end
