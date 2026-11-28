export type Attendee = { name: string; email: string | null; status: string; organizer: boolean; me: boolean };
export type Meeting = { provider: string; url: string };

export type ApiEvent = {
  id: string;
  title: string;
  start: string;
  end: string;
  all_day: boolean;
  time_zone: string | null;
  location: string | null;
  notes: string | null;
  html_link: string | null;
  meeting: Meeting | null;
  attendees: Attendee[];
  my_status: string | null;
  declined: boolean;
  can_respond: boolean;
  recurring: boolean;
  busy: boolean;
  cancelled: boolean;
};

export type Status = {
  storage: boolean;
  has_client: boolean;
  connected: boolean;
  email: string | null;
  connecting: boolean;
  error: string | null;
};

export type Quick = {
  title: string;
  start: string;
  end: string;
  all_day: boolean;
  location: string | null;
  calendar_name: string | null;
  has_date: boolean;
  has_time: boolean;
};

export type ViewMode = "day" | "week" | "month";
export type Choice = "accepted" | "tentative" | "declined";
