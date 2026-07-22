<?php
/**
 *       \file       /ticket/class/ticketsmicroserviceclient.class.php
 *       \ingroup    ticket
 *       \brief      HTTP client for the standalone Tickets microservice.
 *
 * This is a modernization experiment: the ticket create/list/view flows in
 * card.php and list.php are wired to call an external Laravel microservice
 * (its own Postgres database, no relation to llx_ticket) instead of the
 * Ticket class' own persistence. Edit/close/assign and other actions are
 * intentionally out of scope and still operate on llx_ticket, so tickets
 * created through this client cannot be edited/closed from this UI yet.
 */

require_once DOL_DOCUMENT_ROOT.'/core/lib/geturl.lib.php';

/**
 * Thin HTTP client for the Tickets microservice (http://localhost:8001/api by default).
 */
class TicketsMicroserviceClient
{
	/**
	 * @var string Base URL of the microservice API, no trailing slash.
	 */
	private $baseUrl;

	/**
	 * @var string Last error message, if any call failed.
	 */
	public $error = '';

	public function __construct()
	{
		// This runs server-side inside the "web" container, so it must use
		// the internal Docker network URL, not the host-exposed one. Read
		// from the environment (set via dev/build/docker-dev/.env, see
		// docker-compose.yml) first; fall back to the llx_const value for
		// setups where the env var isn't wired, then a hardcoded default.
		$this->baseUrl = getenv('TICKETS_MICROSERVICE_URL_INTERNAL')
			?: getDolGlobalString('TICKETS_MICROSERVICE_URL', 'http://tickets-microservice:8000/api');
	}

	/**
	 * Create a ticket via the microservice.
	 *
	 * @param	string	$subject	Ticket subject
	 * @param	string	$message	Ticket message
	 * @return	array|int<-1,-1>	Decoded ticket on success, -1 on failure ($this->error is set)
	 */
	public function createTicket($subject, $message)
	{
		$payload = json_encode(array('subject' => $subject, 'message' => $message));

		$result = getURLContent(
			$this->baseUrl.'/tickets',
			'POSTALREADYFORMATED',
			$payload,
			1,
			array('Content-Type: application/json'),
			array('http', 'https'),
			2 // allow localhost as this is a same-host dev service
		);

		if (empty($result['http_code']) || $result['http_code'] < 200 || $result['http_code'] >= 300) {
			$this->error = 'Tickets microservice error (HTTP '.($result['http_code'] ?? 0).'): '.($result['content'] ?? $result['curl_error_msg'] ?? 'unknown error');
			return -1;
		}

		$decoded = json_decode($result['content'], true);
		if (!is_array($decoded)) {
			$this->error = 'Tickets microservice returned an unexpected response: '.$result['content'];
			return -1;
		}

		return $decoded;
	}

	/**
	 * Fetch a single ticket by id.
	 *
	 * @param	int		$id		Ticket id in the microservice
	 * @return	array|int<-1,-1>	Decoded ticket on success, -1 on failure (404 included)
	 */
	public function getTicket($id)
	{
		$result = getURLContent($this->baseUrl.'/tickets/'.((int) $id), 'GET', '', 1, array(), array('http', 'https'), 2);

		if (empty($result['http_code']) || $result['http_code'] < 200 || $result['http_code'] >= 300) {
			$this->error = 'Tickets microservice error (HTTP '.($result['http_code'] ?? 0).'): '.($result['content'] ?? $result['curl_error_msg'] ?? 'unknown error');
			return -1;
		}

		$decoded = json_decode($result['content'], true);
		if (!is_array($decoded)) {
			$this->error = 'Tickets microservice returned an unexpected response: '.$result['content'];
			return -1;
		}

		return $decoded;
	}

	/**
	 * List all tickets.
	 *
	 * @return	array<int,array>|int<-1,-1>	Array of decoded tickets on success, -1 on failure
	 */
	public function listTickets()
	{
		$result = getURLContent($this->baseUrl.'/tickets', 'GET', '', 1, array(), array('http', 'https'), 2);

		if (empty($result['http_code']) || $result['http_code'] < 200 || $result['http_code'] >= 300) {
			$this->error = 'Tickets microservice error (HTTP '.($result['http_code'] ?? 0).'): '.($result['content'] ?? $result['curl_error_msg'] ?? 'unknown error');
			return -1;
		}

		$decoded = json_decode($result['content'], true);
		if (!is_array($decoded)) {
			$this->error = 'Tickets microservice returned an unexpected response: '.$result['content'];
			return -1;
		}

		return $decoded;
	}

	/**
	 * Map a microservice ticket (array) onto a Ticket object's in-memory
	 * properties, without touching llx_ticket. Mirrors what
	 * Ticket::setVarsFromFetchObj does when hydrating from a DB row.
	 *
	 * @param	Ticket	$object			Ticket object to populate
	 * @param	array	$msTicket		Decoded ticket from the microservice
	 * @return	void
	 */
	public function hydrateTicketObject(&$object, array $msTicket)
	{
		$object->id = (int) $msTicket['id'];
		$object->ref = $msTicket['ref'];
		$object->track_id = $msTicket['ref']; // microservice has no separate track_id
		$object->subject = $msTicket['subject'];
		$object->message = $msTicket['message'];
		$object->fk_soc = $msTicket['fk_soc'] ?? null;
		$object->status = ($msTicket['status'] === 'open') ? Ticket::STATUS_NOT_READ : $object->status;
		$object->datec = !empty($msTicket['created_at']) ? strtotime($msTicket['created_at']) : null;
		$object->date_close = !empty($msTicket['date_close']) ? strtotime($msTicket['date_close']) : null;
	}
}
