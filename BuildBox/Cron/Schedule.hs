{-# LANGUAGE ScopedTypeVariables, PatternGuards #-}
{-# OPTIONS -fno-warn-orphans #-}

-- | A schedule of commands that should be run at a certain time.
module BuildBox.Cron.Schedule
	( 
	-- * Time Periods
	  second, minute, hour, day

	-- * When
	, When		(..)
	, WhenModifier	(..)

	-- * Events
	, EventName
	, Event		(..)
	, earliestEventToStartNow
	, eventCouldStartNow

	-- * Schedules
	, Schedule	(..)
	, makeSchedule
	, lookupEventOfSchedule
	, lookupCommandOfSchedule
	, adjustEventOfSchedule
	, eventsOfSchedule)
where
import Data.Time
import Data.List
import Data.Function
import Data.Maybe
import Control.Monad
import Data.Map			(Map)
import qualified Data.Map	as Map


instance Read NominalDiffTime where
 readsPrec n str
  = let	[(secs :: Double, rest)] = readsPrec n str
    in	case rest of
		's' : rest'	-> [(fromRational $ toRational secs, rest')]
		_		-> []

second, minute, hour, day :: NominalDiffTime
second	= 1
minute  = 60
hour	= 60 * minute
day	= 24 * hour


-- When -------------------------------------------------------------------------------------------
-- | When to invoke some event.
data When
	-- | Just keep doing it.
	= Always

	-- | Don't do it, ever.
	| Never

	-- | Do it some time after we last started it.
	| Every NominalDiffTime
	
	-- | Do it some time after it last finished.
	| After NominalDiffTime
	
	-- | Do it each day at this time.
	| Daily TimeOfDay
	deriving (Read, Show, Eq)


-- | Modifier to when.
data WhenModifier
	-- | If the event hasn't been invoked before then do it immediately
	--   on program start.
	= Immediate

	-- | Skip the first invocation.
	| SkipFirst
	deriving (Read, Show, Eq)


-- Event ------------------------------------------------------------------------------------------
type EventName	= String

-- | Records when an event should start, and when it last ran.
data Event
	= Event
	{ -- | A unique name for this event.
	  --   Used when writing the schedule to a file.
	  eventName		:: EventName

	  -- | When to run the command.
	, eventWhen		:: When

	  -- | Modifier to the previous.
	, eventWhenModifier	:: Maybe WhenModifier

	  -- | Records whether we've skipped a potential invocation.
	  --   Used to manage the `SkipFirst` modifier.
	, eventSkipped		:: Bool

	  -- | When the event was last started, if any.
	, eventLastStarted	:: Maybe UTCTime
		
	  -- | When the event last finished, if any.
	, eventLastEnded	:: Maybe UTCTime }
	deriving (Read, Show, Eq)
	

-- | Given the current time and a list of events, determine which one should be started now.
--   If several events are avaliable then take the one with the earliest start time.
earliestEventToStartNow :: UTCTime -> [Event] -> Maybe Event
earliestEventToStartNow curTime events
 = let	eventsStartable	= filter (eventCouldStartNow curTime)   events
	eventsSorted	= sortBy (compare `on` eventLastStarted) eventsStartable
   in	listToMaybe eventsSorted


-- | Given the current time, decide whether an event could be started.
--   If the `WhenModifier` is `Immediate` this always returns true.
--   The `SkipFirst` modifier is ignored, as this is handled separately.
eventCouldStartNow :: UTCTime -> Event -> Bool
eventCouldStartNow curTime event
 
	-- If the current end time is before the start time, 
	-- then the most recent iteration is still running, 
	-- so don't start it again.
	| Just lastStarted	<- eventLastStarted event
 	, Just lastEnded	<- eventLastEnded   event
 	= lastEnded < lastStarted
 
	-- If the event has never started or ended, and is 
	-- marked as immediate, then start it right away.
	| Nothing		<- eventLastStarted  event
	, Nothing		<- eventLastEnded    event
	, Just Immediate	<- eventWhenModifier event
	= True

	-- Otherwise we have to look at the real schedule.
	| otherwise
	= case eventWhen event of
		Always		-> True
		Never		-> False

		Every diffTime	
	 	 -> maybe True
			(\lastTime -> (curTime `diffUTCTime` lastTime ) > diffTime)
			(eventLastStarted event)

		After diffTime	
	 	 -> maybe True
			(\lastTime -> (curTime `diffUTCTime` lastTime ) > diffTime)
			(eventLastEnded event)
	
		Daily timeOfDay
		 -- If it's been more than a day since we last started it, then do it now.
		 | Just lastStarted	<- eventLastStarted event
		 , (curTime `diffUTCTime` lastStarted) > day
		 -> True
		
		 | otherwise
		 -> let	-- If we were going to run it today, this is when it would be.
			startTimeToday
				= curTime
				{ utctDayTime	= timeOfDayToTime timeOfDay }
				
			-- If it's after that time then quit fooling around..
		    in	curTime > startTimeToday


-- Schedule ---------------------------------------------------------------------------------------
-- | Map of event names to their event details and build commands.
data Schedule cmd
	= Schedule (Map EventName (Event, cmd))


-- | Get the list of events in a schedule, ignoring the build commands.
eventsOfSchedule :: Schedule cmd -> [Event]
eventsOfSchedule (Schedule sched)
	= map fst $ Map.elems sched


-- | A nice way to produce a schedule.
--   TODO: also checks that the names are unique.
makeSchedule :: [(EventName, When, Maybe WhenModifier, cmd)] -> Schedule cmd
makeSchedule tuples
 = let	makeSched (name, whn, mMod, cmd)
	  =	(name, (Event name whn mMod False Nothing Nothing, cmd))
   in	Schedule $ Map.fromList $ map makeSched tuples


-- | Given an event name, lookup the associated event from a schedule.
lookupEventOfSchedule :: EventName -> Schedule cmd -> Maybe Event
lookupEventOfSchedule name (Schedule sched)
	= liftM fst $ Map.lookup name sched
	
	
-- | Given an event name, lookup the associated build command from a schedule.
lookupCommandOfSchedule :: EventName -> Schedule cmd -> Maybe cmd
lookupCommandOfSchedule name (Schedule sched)
	= liftM snd $ Map.lookup name sched


-- | Add this event to a schedule, overwriting any version already there.
--   If the event is present in the schedule, then return the original.
adjustEventOfSchedule :: Event -> Schedule cmd -> Schedule cmd
adjustEventOfSchedule event (Schedule sched)
	= Schedule 
	$ Map.adjust 
		(\(_, build) -> (event, build))
		(eventName event) 
		sched